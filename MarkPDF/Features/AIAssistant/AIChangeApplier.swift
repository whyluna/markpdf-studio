import Darwin
import Foundation
import os

/// 变更应用引擎（FR-AI.5）：把审查通过的提案落到编辑器/文件系统。
/// 三分支路由——文件开着（任一窗口）以编辑器内存文本为基准经内核单事务替换
///（⌘Z 一步回、未落盘编辑不丢）；未打开走磁盘原子写；新建走独立创建并打开标签。
/// 应用时刻对当前文本重新校验：提案后用户手改文件只冲突对应块（跳过并如实报告），
/// 不整批失败。检查点留内存（AIChangeStore 持有），支撑「撤销」整批回滚。
enum AIChangeApplier {
  private enum ExclusiveCreateResult: Equatable {
    case success
    case exists
    case failed
  }
  /// 应用环境（生产接线在 WindowSession.wireUp；测试注入替身）
  struct Environment {
    /// 文件开着时的编辑状态（跨窗口查找；返回的 store 即应用基准）
    var findEditorStore: (URL) -> EditorStore? = { _ in nil }
    /// 经内核整文替换（单事务入撤销栈，⌘Z 一步回）；内核不活/失败回 false
    var applyViaKernel: (EditorStore, String, @escaping (Bool) -> Void) -> Void = { _, _, completion in completion(false) }
    /// 把结果文本同步进 Native store 并直接落盘。内核成功时也必须调用：Web 的
    /// contentChanged 有防抖，若卡片状态更新触发视图重建，旧 store.text 会让新 WebView
    /// 短暂重载旧文；同步后再完成 apply 才能保证当前标签立即收敛。
    var persistViaStore: (EditorStore, String) -> Void = { _, _ in }
    var workspaceRoot: () -> URL? = { nil }
    /// 编辑应用成功后：编辑器高亮改动行并滚到首处改动（FR-AI.6）
    var highlightApplied: (URL, [[Int]], Int) -> Void = { _, _, _ in }
    /// 新建成功后把文件打开成标签（聚焦）
    var openTab: (URL) -> Void = { _ in }
    var refreshTree: () -> Void = {}
    /// 撤销「新建」：入废纸篓（可恢复）
    var trashFile: (URL) -> Bool = { _ in false }
    /// 入废纸篓联动：打开中的标签转草稿（防自动保存把文件复活）
    var notifyTrashed: (URL) -> Void = { _ in }
  }

  /// 单文件应用结果
  struct FileResult: Equatable {
    var path: String
    var outcome: Outcome
    /// 编辑成功后的全文，仅供构造安全撤销检查点；不进入 UI 文案。
    var resultingText: String? = nil

    enum Outcome: Equatable {
      case created
      case edited(appliedEdits: Int, skippedEdits: Int)
      case folderCreated
      case failed(String)
    }

    var isFailure: Bool {
      if case .failed = outcome { return true }
      return false
    }
  }

  /// 批级检查点：应用前的现场快照（撤销时整批回滚）
  struct BatchCheckpoint: Equatable, Codable {
    /// 被编辑文件的变更前全文（撤销 = 恢复）
    var editedSnapshots: [EditedSnapshot] = []
    /// 本批实际成功新建的文件/文件夹（撤销前核验仍保持应用后状态）
    var createdSnapshots: [CreatedSnapshot] = []

    struct EditedSnapshot: Equatable, Codable {
      var url: URL
      var beforeText: String
      /// 应用后的精确全文。当前内容与它不一致时拒绝整文恢复，保护后续用户编辑。
      var afterText: String?
    }

    struct CreatedSnapshot: Equatable, Codable {
      enum Kind: String, Codable {
        case file
        case folder
      }

      var url: URL
      var kind: Kind
      /// 新建文件的原始内容；撤销前必须逐字一致。文件夹则为 nil 且必须保持为空。
      var expectedText: String?
    }

    var createdPaths: [URL] { createdSnapshots.map(\.url) }
    var isEmpty: Bool { editedSnapshots.isEmpty && createdSnapshots.isEmpty }

    mutating func merge(_ other: BatchCheckpoint) {
      // 同文件多次编辑只留最早快照（恢复到本批开始前的状态）
      for snapshot in other.editedSnapshots where !editedSnapshots.contains(where: { $0.url == snapshot.url }) {
        editedSnapshots.append(snapshot)
      }
      for snapshot in other.createdSnapshots
      where !createdSnapshots.contains(where: { $0.url == snapshot.url }) {
        createdSnapshots.append(snapshot)
      }
    }

    /// 预检查点只在对应操作确实成功后进入批检查点；编辑项同时补齐应用后全文。
    mutating func retainAppliedResult(_ result: FileResult) {
      guard !result.isFailure else {
        editedSnapshots = []
        createdSnapshots = []
        return
      }
      if case .edited = result.outcome {
        guard let resultingText = result.resultingText else {
          editedSnapshots = []
          return
        }
        for index in editedSnapshots.indices {
          editedSnapshots[index].afterText = resultingText
        }
      }
    }
  }

  struct UndoResult: Equatable {
    var results: [FileResult]
    var remainingCheckpoint: BatchCheckpoint
  }

  // MARK: - 检查点

  /// 应用前快照（编辑文件取实时基准文本；新建只记路径）
  static func checkpoint(for change: AIFileChange, environment: Environment) async -> BatchCheckpoint {
    guard let root = environment.workspaceRoot(),
      let resolved = AIToolRegistry.resolveWritePath(change.path, root: root, requireExtension: change.kind == .createFolder ? nil : "md")
    else { return BatchCheckpoint() }
    switch change.kind {
    case .createFile:
      var point = BatchCheckpoint()
      point.createdSnapshots = [BatchCheckpoint.CreatedSnapshot(
        url: resolved.url, kind: .file, expectedText: change.content)]
      return point
    case .createFolder:
      var point = BatchCheckpoint()
      point.createdSnapshots = [BatchCheckpoint.CreatedSnapshot(
        url: resolved.url, kind: .folder, expectedText: nil)]
      return point
    case .editFile:
      var point = BatchCheckpoint()
      if let store = environment.findEditorStore(resolved.url) {
        point.editedSnapshots = [BatchCheckpoint.EditedSnapshot(
          url: resolved.url, beforeText: store.text, afterText: nil)]
      } else {
        let disk = await Task.detached(priority: .userInitiated) {
          try? String(contentsOf: resolved.url, encoding: .utf8)
        }.value
        if let disk {
          point.editedSnapshots = [BatchCheckpoint.EditedSnapshot(
            url: resolved.url, beforeText: disk, afterText: nil)]
        }
      }
      return point
    }
  }

  // MARK: - 应用

  static func apply(_ change: AIFileChange, environment: Environment) async -> FileResult {
    guard let root = environment.workspaceRoot() else {
      return FileResult(path: change.path, outcome: .failed("没有打开的工作区"))
    }
    guard let resolved = AIToolRegistry.resolveWritePath(
      change.path, root: root, requireExtension: change.kind == .createFolder ? nil : "md"
    ) else {
      return FileResult(path: change.path, outcome: .failed("路径非法或越出工作区"))
    }
    switch change.kind {
    case .createFile: return await createFile(change, at: resolved.url, relative: resolved.relative, environment: environment)
    case .createFolder: return await createFolder(at: resolved.url, relative: resolved.relative, environment: environment)
    case .editFile: return await editFile(change, at: resolved.url, relative: resolved.relative, environment: environment)
    }
  }

  private static func createFile(
    _ change: AIFileChange, at url: URL, relative: String, environment: Environment
  ) async -> FileResult {
    // 父目录链可复用，但目标文件必须以 withoutOverwriting 原子创建：
    // 「先 fileExists 再 write」有 TOCTOU 窗口，会覆盖审批期间由用户创建的同名文件。
    let creation = await Task.detached(priority: .userInitiated) {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return createFileExclusively(at: url, data: Data(change.content.utf8))
      } catch {
        return ExclusiveCreateResult.failed
      }
    }.value
    guard creation == .success else {
      let reason = creation == .exists ? "文件已存在（应用时被占用）" : "创建失败（权限或磁盘错误）"
      return FileResult(path: relative, outcome: .failed(reason))
    }
    environment.refreshTree()
    environment.openTab(url)
    Logger.ai.info("AI 变更应用: 新建 \(url.lastPathComponent, privacy: .public) (\(change.content.count) 字)")
    return FileResult(path: relative, outcome: .created)
  }

  /// POSIX O_EXCL 保证「目标不存在」检查与创建为同一个原子操作；写失败清理本次
  /// 刚创建的残片，不会留下一个未进入撤销检查点的半文件。
  nonisolated private static func createFileExclusively(at url: URL, data: Data) -> ExclusiveCreateResult {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return .failed }
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
      guard descriptor >= 0 else { return errno == EEXIST ? .exists : .failed }
      var succeeded = true
      data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
          let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
          if count > 0 {
            offset += count
          } else if count < 0, errno == EINTR {
            continue
          } else {
            succeeded = false
            break
          }
        }
      }
      if close(descriptor) != 0 { succeeded = false }
      if !succeeded {
        _ = unlink(path)
        return .failed
      }
      return .success
    }
  }

  private static func createFolder(
    at url: URL, relative: String, environment: Environment
  ) async -> FileResult {
    // 中间父目录允许复用，最终目录用 POSIX mkdir 独占创建；FileManager 的
    // withIntermediateDirectories=true 遇到已存在目标仍返回成功，随后撤销会误删用户目录。
    let created: Bool = await Task.detached(priority: .userInitiated) {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url.withUnsafeFileSystemRepresentation { path in
          guard let path else { return false }
          return mkdir(path, S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) == 0
        }
      } catch {
        return false
      }
    }.value
    guard created else {
      return FileResult(path: relative, outcome: .failed("创建失败（权限或磁盘错误）"))
    }
    environment.refreshTree()
    return FileResult(path: relative, outcome: .folderCreated)
  }

  private static func editFile(
    _ change: AIFileChange, at url: URL, relative: String, environment: Environment
  ) async -> FileResult {
    // 分支①：文件开着（任一窗口）——以编辑器内存文本为基准，未落盘编辑不丢
    if let store = environment.findEditorStore(url) {
      let outcome = AIEditApplication.apply(change.edits, to: store.text)
      guard outcome.appliedCount > 0 else {
        return FileResult(
          path: relative,
          outcome: .failed("文件已变化，\(outcome.skippedCount) 处修改全部无法匹配（未应用）")
        )
      }
      return await applyEditText(
        at: url, relative: relative, newText: outcome.text, environment: environment,
        appliedEdits: outcome.appliedCount, skippedEdits: outcome.skippedCount, changedLineCount: nil)
    }
    // 分支②：未打开——磁盘读改写（原子）
    let disk = await Task.detached(priority: .userInitiated) {
      try? String(contentsOf: url, encoding: .utf8)
    }.value
    guard let disk else {
      return FileResult(path: relative, outcome: .failed("无法读取文件（可能已被移动或删除）"))
    }
    let outcome = AIEditApplication.apply(change.edits, to: disk)
    guard outcome.appliedCount > 0 else {
      return FileResult(
        path: relative,
        outcome: .failed("文件已变化，\(outcome.skippedCount) 处修改全部无法匹配（未应用）")
      )
    }
    return await applyEditText(
      at: url, relative: relative, newText: outcome.text, environment: environment,
      appliedEdits: outcome.appliedCount, skippedEdits: outcome.skippedCount, changedLineCount: nil)
  }

  /// 审查后的应用（FR-AI.6）：effectiveEdits = 按勾选拼好的编辑列表
  ///（全拒块已剔除、部分接受块已缩水 new_text）；应用时刻逐条重新校验（漂移只影响
  /// 漂移条目，如实计数），高亮取最终文本的 diff
  static func applyReviewedEdits(
    _ change: AIFileChange,
    effectiveEdits: [AIFileChange.TextEdit],
    environment: Environment
  ) async -> FileResult {
    guard let root = environment.workspaceRoot() else {
      return FileResult(path: change.path, outcome: .failed("没有打开的工作区"))
    }
    guard let resolved = AIToolRegistry.resolveWritePath(change.path, root: root, requireExtension: "md") else {
      return FileResult(path: change.path, outcome: .failed("路径非法或越出工作区"))
    }
    guard !effectiveEdits.isEmpty else {
      return FileResult(path: change.path, outcome: .failed("所有修改块都被取消勾选（未应用）"))
    }
    let currentBase: String?
    if let store = environment.findEditorStore(resolved.url) {
      currentBase = store.text
    } else {
      currentBase = await Task.detached(priority: .userInitiated) {
        try? String(contentsOf: resolved.url, encoding: .utf8)
      }.value
    }
    guard let currentBase else {
      return FileResult(path: change.path, outcome: .failed("无法读取文件（可能已被移动或删除）"))
    }
    let outcome = AIEditApplication.apply(effectiveEdits, to: currentBase)
    guard outcome.appliedCount > 0 else {
      return FileResult(
        path: change.path,
        outcome: .failed("文件已变化，勾选的 \(outcome.skippedCount) 处修改均无法匹配（未应用）")
      )
    }
    let diffHunks = LineDiff.diff(currentBase, outcome.text)
    return await applyEditText(
      at: resolved.url, relative: resolved.relative, newText: outcome.text, environment: environment,
      appliedEdits: outcome.appliedCount,
      skippedEdits: outcome.skippedCount,
      changedLineCount: nil,
      highlight: Self.highlightRanges(from: diffHunks))
  }

  /// 接受 hunk 的新增行号 → 连续行段 [[起, 止]]（1 起闭区间）与首段行号
  static func highlightRanges(from hunks: [LineDiff.Hunk]) -> (ranges: [[Int]], firstLine: Int)? {
    let numbers = hunks.flatMap { hunk in
      hunk.lines.filter { $0.kind == .added }.compactMap(\.newNumber)
    }.sorted()
    guard !numbers.isEmpty else { return nil }
    var ranges: [[Int]] = []
    var runStart = numbers[0]
    var previous = numbers[0]
    for number in numbers.dropFirst() {
      if number == previous + 1 {
        previous = number
        continue
      }
      ranges.append([runStart, previous])
      runStart = number
      previous = number
    }
    ranges.append([runStart, previous])
    return (ranges, numbers[0])
  }

  /// 统一的「写最终文本」出口：开着走内核单事务（⌘Z 一步回），否则磁盘原子写
  private static func applyEditText(
    at url: URL,
    relative: String,
    newText: String,
    environment: Environment,
    appliedEdits: Int,
    skippedEdits: Int,
    changedLineCount: Int?,
    highlight: (ranges: [[Int]], firstLine: Int)? = nil
  ) async -> FileResult {
    if let store = environment.findEditorStore(url) {
      _ = await withCheckedContinuation { continuation in
        environment.applyViaKernel(store, newText) { continuation.resume(returning: $0) }
      }
      // 不论内核是否成功都先同步 Native 权威状态。成功分支不能只等 Web 侧
      // contentChanged 防抖回传，否则应用完成与 store 更新之间存在可见旧内容窗口。
      environment.persistViaStore(store, newText)
      if let highlight {
        environment.highlightApplied(url, highlight.ranges, highlight.firstLine)
      }
      return FileResult(
        path: relative,
        outcome: .edited(appliedEdits: appliedEdits, skippedEdits: skippedEdits),
        resultingText: newText)
    }
    let written: Bool = await Task.detached(priority: .userInitiated) {
      (try? newText.write(to: url, atomically: true, encoding: .utf8)) != nil
    }.value
    guard written else {
      return FileResult(path: relative, outcome: .failed("写盘失败（权限或磁盘错误）"))
    }
    environment.refreshTree()
    Logger.ai.info("AI 变更应用: 编辑 \(url.lastPathComponent, privacy: .public)（\(appliedEdits)/\(appliedEdits + skippedEdits) 块）")
    return FileResult(
      path: relative,
      outcome: .edited(appliedEdits: appliedEdits, skippedEdits: skippedEdits),
      resultingText: newText)
  }

  // MARK: - 撤销（整批回滚）

  /// 恢复被编辑文件 → 新建项入废纸篓。每一项先核验仍等于 AI 应用后的状态；
  /// 用户在应用后继续编辑/向新文件夹加入内容时拒绝覆盖或删除，并保留检查点供重试。
  static func undo(_ checkpoint: BatchCheckpoint, environment: Environment) async -> UndoResult {
    var results: [FileResult] = []
    var remaining = BatchCheckpoint()
    for snapshot in checkpoint.editedSnapshots {
      guard let expected = snapshot.afterText else {
        results.append(FileResult(path: snapshot.url.lastPathComponent, outcome: .failed("缺少安全撤销校验信息")))
        remaining.editedSnapshots.append(snapshot)
        continue
      }
      if let store = environment.findEditorStore(snapshot.url) {
        guard store.text == expected else {
          results.append(FileResult(path: snapshot.url.lastPathComponent, outcome: .failed("应用后文件又被编辑，已保护后续内容")))
          remaining.editedSnapshots.append(snapshot)
          continue
        }
        _ = await withCheckedContinuation { continuation in
          environment.applyViaKernel(store, snapshot.beforeText) { continuation.resume(returning: $0) }
        }
        environment.persistViaStore(store, snapshot.beforeText)
      } else {
        let current = await Task.detached(priority: .userInitiated) {
          try? String(contentsOf: snapshot.url, encoding: .utf8)
        }.value
        guard current == expected else {
          results.append(FileResult(path: snapshot.url.lastPathComponent, outcome: .failed("应用后文件又被编辑，已保护后续内容")))
          remaining.editedSnapshots.append(snapshot)
          continue
        }
        let restored: Bool = await Task.detached(priority: .userInitiated) {
          (try? snapshot.beforeText.write(to: snapshot.url, atomically: true, encoding: .utf8)) != nil
        }.value
        guard restored else {
          results.append(FileResult(path: snapshot.url.lastPathComponent, outcome: .failed("恢复失败")))
          remaining.editedSnapshots.append(snapshot)
          continue
        }
      }
      environment.refreshTree()
      results.append(FileResult(path: snapshot.url.lastPathComponent, outcome: .edited(appliedEdits: 1, skippedEdits: 0)))
    }
    // 深度逆序：先删文件后删其父文件夹；只有文件内容未变/目录仍为空才允许入废纸篓。
    for snapshot in checkpoint.createdSnapshots.sorted(by: {
      $0.url.pathComponents.count > $1.url.pathComponents.count
    }) {
      let unchanged = await createdItemIsUnchanged(snapshot, environment: environment)
      guard unchanged else {
        results.append(FileResult(
          path: snapshot.url.lastPathComponent,
          outcome: .failed("新建项在应用后已变化，未移入废纸篓")))
        remaining.createdSnapshots.append(snapshot)
        continue
      }
      environment.notifyTrashed(snapshot.url)
      let trashed = environment.trashFile(snapshot.url)
      if !trashed {
        results.append(FileResult(path: snapshot.url.lastPathComponent, outcome: .failed("撤销新建失败（入废纸篓未成功）")))
        remaining.createdSnapshots.append(snapshot)
      }
    }
    environment.refreshTree()
    Logger.ai.info("AI 变更撤销: 恢复 \(checkpoint.editedSnapshots.count) 文件 / 废纸篓 \(checkpoint.createdPaths.count) 项")
    return UndoResult(results: results, remainingCheckpoint: remaining)
  }

  private static func createdItemIsUnchanged(
    _ snapshot: BatchCheckpoint.CreatedSnapshot,
    environment: Environment
  ) async -> Bool {
    switch snapshot.kind {
    case .file:
      guard let expected = snapshot.expectedText else { return false }
      if let store = environment.findEditorStore(snapshot.url) {
        return store.text == expected
      }
      return await Task.detached(priority: .userInitiated) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: snapshot.url.path),
          attributes[.type] as? FileAttributeType == .typeRegular
        else { return false }
        return (try? String(contentsOf: snapshot.url, encoding: .utf8)) == expected
      }.value
    case .folder:
      return await Task.detached(priority: .userInitiated) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: snapshot.url.path),
          attributes[.type] as? FileAttributeType == .typeDirectory,
          let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshot.url, includingPropertiesForKeys: nil)
        else { return false }
        return contents.isEmpty
      }.value
    }
  }
}
