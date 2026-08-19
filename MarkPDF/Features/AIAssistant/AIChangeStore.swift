import Foundation
import os

/// 变更审查状态机（FR-AI.5）：agent 产出的写提案在此排队、封存、审查、应用与撤销。
/// 生命周期：循环内 enqueue 收提案 → 循环结束 sealPending 封存成变更集（挂聊天卡片）
/// → 用户应用/拒绝 → 应用后留检查点供撤销。检查点仅存内存（关窗即失效——已知边界）。
@MainActor
final class AIChangeStore: ObservableObject {
  /// 变更集审查状态
  enum Status: Equatable, Codable {
    case pending
    /// 应用进行中（即时反馈：按钮换进度指示）
    case applying
    /// 应用结果摘要（含失败项说明）
    case applied(String)
    case undone
    case rejected
  }

  /// 已封存的变更集（卡片按 ID 引用渲染；id 即变更集 id——消息挂的与这里查的是同一个）
  struct SealedChangeSet: Identifiable, Equatable {
    var set: AIChangeSet
    var status: Status = .pending
    var checkpoint: AIChangeApplier.BatchCheckpoint?
    /// 逐文件审查数据（diff hunks 与勾选态；卡片出现时异步准备，见 prepareReviewIfNeeded）
    var reviews: [UUID: FileReview] = [:]

    // 属性名 set 在花括号内会被按 setter 关键字解析，须 self. 前缀消歧
    var id: UUID { self.set.id }
  }

  /// 单个审查单元（FR-AI.6）：模型编辑块**内部**的一个 diff 变更段
  ///（git add -p / Aider 的审查单位 = 变更段而非提案块——模型把多处修改塞进
  /// 一个大 old_text/new_text 时，这里仍逐段展示与勾选）。
  /// 行号已按块在基准文本中的位置平移为绝对行号
  struct ReviewUnit: Identifiable, Equatable, Codable {
    /// "e{编辑块下标}h{块内变更段下标}"——稳定且携带应用时的归属信息
    let id: String
    let editIndex: Int
    let hunk: LineDiff.Hunk
    var isAccepted = true

    var changeCount: Int { hunk.changeCount }
  }

  /// 单文件审查数据（FR-AI.6）：editFile = 基准快照 + 逐变更段 diff；
  /// createFile = 待写内容展示。勾选默认全接受
  struct FileReview: Equatable, Codable {
    var kind: AIFileChange.Kind
    var path: String
    /// editFile：封存时刻的基准文本
    var baseText: String?
    /// editFile：全部编辑块应用后的提案全文；createFile：待写入内容
    var proposedText: String?
    var units: [ReviewUnit] = []
    /// 封存时 old_text 已无法匹配而被丢弃的编辑块数（如实展示）
    var skippedEditCount = 0

    var acceptedUnitCount: Int { units.filter(\.isAccepted).count }

    /// 按勾选生成应用时的有效编辑列表：全段接受的块用原 new_text；
    /// 部分接受的块拼接出缩水的 new_text；全拒的块剔除
    func effectiveEdits(_ edits: [AIFileChange.TextEdit]) -> [AIFileChange.TextEdit] {
      var result: [AIFileChange.TextEdit] = []
      for (editIndex, edit) in edits.enumerated() {
        let editUnits = units.filter { $0.editIndex == editIndex }
        if editUnits.isEmpty { continue }  // 该块全段被取消
        if editUnits.allSatisfy(\.isAccepted) {
          result.append(edit)
          continue
        }
        // applying 按 hunk 自身 id 匹配：须把「单元勾选」换算成「hunk id 集合」
        let acceptedHunkIDs = Set(editUnits.filter(\.isAccepted).map(\.hunk.id))
        let newText = LineDiff.applying(
          editUnits.map(\.hunk), accepted: acceptedHunkIDs, to: edit.oldText)
        if newText != edit.oldText {
          result.append(AIFileChange.TextEdit(oldText: edit.oldText, newText: newText))
        }
      }
      return result
    }
  }

  /// 保留的封存变更集上限（防会话内无界增长；被淘汰的卡片随消息保留但不再可操作）
  static let sealedRetention = 20

  @Published private(set) var sealedSets: [SealedChangeSet] = []
  /// 循环内累积、尚未封存的提案数（面板徽标用；跨桶合计）
  @Published private(set) var pendingProposalCount = 0

  /// 应用环境（WindowSession.wireUp 接线；测试注入替身）
  var applierEnvironment: AIChangeApplier.Environment?

  /// 供下一轮注入模型的审查结果注记（消费即清）
  private var outcomeNotes: [String] = []

  /// 未封存提案按运行分桶（bucket = 线程键）：多文档并行运行互不串卡，
  /// 各自封存各自的提案
  private var pendingBuckets: [String: [AIFileChange]] = [:]

  // MARK: - 提案入队（agent 循环，主线程）

  /// 同文件同类合并：editFile 追加块（模型分多次提案同文件）；新建后提覆盖先提
  func enqueue(_ change: AIFileChange, bucket: String = "") {
    var list = pendingBuckets[bucket] ?? []
    if let index = list.lastIndex(where: { $0.kind == change.kind && $0.path == change.path }) {
      if change.kind == .editFile {
        list[index].edits.append(contentsOf: change.edits)
      } else {
        list[index] = change
      }
    } else {
      list.append(change)
    }
    pendingBuckets[bucket] = list
    pendingProposalCount = pendingBuckets.values.reduce(0) { $0 + $1.count }
  }

  /// 循环结束封存本桶 pending → 变更集（空集不封存返回 nil）
  @discardableResult
  func sealPending(bucket: String = "") -> AIChangeSet? {
    guard let changes = pendingBuckets[bucket], !changes.isEmpty else { return nil }
    pendingBuckets.removeValue(forKey: bucket)
    pendingProposalCount = pendingBuckets.values.reduce(0) { $0 + $1.count }
    var set = AIChangeSet()
    set.changes = changes
    sealedSets.append(SealedChangeSet(set: set))
    trimSealed()
    return set
  }

  /// 丢弃全部未封存提案（切换工作区等场景，防悬空提案漂到新工作区）
  func discardPending() {
    pendingBuckets = [:]
    pendingProposalCount = 0
  }

  // MARK: - 持久化（卡片随会话存取；重启后回看与撤销可用）

  /// 导出消息仍引用的变更集（按 id 过滤；检查点不落盘——撤销时按审查基准重建）
  func serializableSets(referencing ids: Set<UUID>) -> [AISessionStore.StoredChangeSet] {
    sealedSets
      .filter { ids.contains($0.id) }
      .map { entry in
        AISessionStore.StoredChangeSet(
          id: entry.id.uuidString,
          changeSet: entry.set,
          status: entry.status,
          reviews: Dictionary(
            uniqueKeysWithValues: entry.reviews.map { (key, value) in (key.uuidString, value) })

        )
      }
  }

  /// 从会话存储恢复变更集（内存已有同 id 者以内存为准——活窗口状态更新）
  func restoreSets(_ stored: [AISessionStore.StoredChangeSet]) {
    let known = Set(sealedSets.map(\.id))
    for entry in stored {
      guard let id = UUID(uuidString: entry.id), !known.contains(id) else { continue }
      var reviews: [UUID: FileReview] = [:]
      for (key, value) in entry.reviews {
        if let fileID = UUID(uuidString: key) { reviews[fileID] = value }
      }
      sealedSets.append(SealedChangeSet(set: entry.changeSet, status: entry.status, checkpoint: nil, reviews: reviews))
    }
  }

  /// 工作区切换：未审查的变更集全部作废（路径按旧根解析，应用到新根会开出意外文件）
  func rejectPendingSets() {
    for index in sealedSets.indices where sealedSets[index].status == .pending {
      sealedSets[index].status = .rejected
    }
    discardPending()
  }

  func changeSet(id: UUID) -> SealedChangeSet? {
    sealedSets.first { $0.id == id }
  }

  // MARK: - 审查数据（FR-AI.6）

  /// 卡片出现时异步准备逐文件审查数据（基准文本取编辑器实时内存，未打开读盘）
  func prepareReviewsIfNeeded(_ changeSetID: UUID) async {
    guard let index = sealedSets.firstIndex(where: { $0.id == changeSetID }),
      sealedSets[index].reviews.isEmpty,
      let environment = applierEnvironment,
      let root = environment.workspaceRoot()
    else { return }
    var reviews: [UUID: FileReview] = [:]
    for change in sealedSets[index].set.changes {
      switch change.kind {
      case .createFolder:
        continue
      case .createFile:
        reviews[change.id] = FileReview(kind: .createFile, path: change.path, proposedText: change.content)
      case .editFile:
        guard let resolved = AIToolRegistry.resolveWritePath(change.path, root: root, requireExtension: "md") else { continue }
        let base: String?
        if let store = environment.findEditorStore(resolved.url) {
          base = store.text
        } else {
          base = await Task.detached(priority: .userInitiated) {
            try? String(contentsOf: resolved.url, encoding: .utf8)
          }.value
        }
        guard let base else { continue }
        let outcome = AIEditApplication.apply(change.edits, to: base)
        // 审查单元 = 编辑块内部的每个 diff 变更段（行号平移为基准文本的绝对行号）
        var units: [ReviewUnit] = []
        for (editIndex, edit) in change.edits.enumerated() where outcome.appliedIndices.contains(editIndex) {
          let offset = Self.lineOffset(of: edit.oldText, in: base)
          for (hunkIndex, hunk) in LineDiff.diff(edit.oldText, edit.newText, context: 3).enumerated() {
            units.append(ReviewUnit(
              id: "e\(editIndex)h\(hunkIndex)",
              editIndex: editIndex,
              hunk: Self.shifted(hunk, by: offset)
            ))
          }
        }
        reviews[change.id] = FileReview(
          kind: .editFile,
          path: change.path,
          baseText: base,
          proposedText: outcome.text,
          units: units,
          skippedEditCount: outcome.skippedCount
        )
      }
    }
    guard let currentIndex = sealedSets.firstIndex(where: { $0.id == changeSetID }) else { return }
    sealedSets[currentIndex].reviews = reviews
  }

  /// 打开变更涉及的文件（已应用后点文件行用；新建/编辑都聚焦成标签）
  func openChangeFile(_ change: AIFileChange) {
    guard let environment = applierEnvironment,
      let root = environment.workspaceRoot(),
      let resolved = AIToolRegistry.resolveWritePath(
        change.path, root: root, requireExtension: change.kind == .createFolder ? nil : "md")
    else { return }
    environment.openTab(resolved.url)
  }

  /// oldText 在基准文本中的起始行号（0 起）——块内 diff 行号平移用
  private static func lineOffset(of needle: String, in haystack: String) -> Int {
    guard let range = haystack.range(of: needle) else { return 0 }
    return haystack[..<range.lowerBound].filter { $0 == "\n" }.count
  }

  /// hunk 行号整体平移（块内相对 → 文件绝对）
  private static func shifted(_ hunk: LineDiff.Hunk, by offset: Int) -> LineDiff.Hunk {
    LineDiff.Hunk(
      oldStart: hunk.oldStart + offset,
      oldCount: hunk.oldCount,
      newStart: hunk.newStart + offset,
      newCount: hunk.newCount,
      lines: hunk.lines.map { line in
        LineDiff.Line(
          kind: line.kind,
          text: line.text,
          oldNumber: line.oldNumber.map { $0 + offset },
          newNumber: line.newNumber.map { $0 + offset }
        )
      }
    )
  }

  /// 勾选/取消单个审查单元（已应用/已拒绝的变更集不可再动）
  func toggleUnit(_ changeSetID: UUID, changeID: UUID, unitID: String) {
    guard let index = sealedSets.firstIndex(where: { $0.id == changeSetID }),
      sealedSets[index].status == .pending,
      let unitIndex = sealedSets[index].reviews[changeID]?.units.firstIndex(where: { $0.id == unitID })
    else { return }
    sealedSets[index].reviews[changeID]?.units[unitIndex].isAccepted.toggle()
  }

  /// 单文件全接受/全拒绝审查单元
  func setAllUnits(_ changeSetID: UUID, changeID: UUID, accepted: Bool) {
    guard let index = sealedSets.firstIndex(where: { $0.id == changeSetID }),
      sealedSets[index].status == .pending,
      let unitIndices = sealedSets[index].reviews[changeID]?.units.indices
    else { return }
    for unitIndex in unitIndices {
      sealedSets[index].reviews[changeID]?.units[unitIndex].isAccepted = accepted
    }
  }

  /// 超限时先淘汰已了结且不可撤销的（rejected/undone），仍超再淘汰最旧的
  private func trimSealed() {
    guard sealedSets.count > Self.sealedRetention else { return }
    while sealedSets.count > Self.sealedRetention,
      let index = sealedSets.firstIndex(where: { $0.status == .rejected || $0.status == .undone })
    {
      sealedSets.remove(at: index)
    }
    while sealedSets.count > Self.sealedRetention {
      sealedSets.removeFirst()
    }
  }

  // MARK: - 审查意图（卡片按钮）

  /// 应用整个变更集（逐文件检查点 → 应用 → 状态收口）。
  /// 先置 .applying 即时反馈（大文件检查点/写盘期间按钮即切换，无需等待）
  func apply(_ changeSetID: UUID) async {
    guard let index = sealedSets.firstIndex(where: { $0.id == changeSetID }),
      sealedSets[index].status == .pending,
      let environment = applierEnvironment
    else { return }
    sealedSets[index].status = .applying
    var entry = sealedSets[index]
    var checkpoint = AIChangeApplier.BatchCheckpoint()
    var results: [AIChangeApplier.FileResult] = []
    // 计时埋点（诊断通道：用户复现「应用→撤销按钮」延迟时读取分解）
    var timing = ["t0=\(Date().timeIntervalSince1970 * 1000)"]
    for change in entry.set.changes {
      let cpStart = Date()
      checkpoint.merge(await AIChangeApplier.checkpoint(for: change, environment: environment))
      timing.append("checkpoint=\(Int(Date().timeIntervalSince(cpStart) * 1000))ms")
      // editFile 有审查数据 → 按勾选拼出有效编辑列表（部分接受的块自动缩水 new_text）
      if change.kind == .editFile, let review = entry.reviews[change.id] {
        let effective = review.effectiveEdits(change.edits)
        let applyStart = Date()
        results.append(
          await AIChangeApplier.applyReviewedEdits(
            change, effectiveEdits: effective, environment: environment
          ))
        timing.append("apply=\(Int(Date().timeIntervalSince(applyStart) * 1000))ms")
      } else {
        let applyStart = Date()
        results.append(await AIChangeApplier.apply(change, environment: environment))
        timing.append("apply=\(Int(Date().timeIntervalSince(applyStart) * 1000))ms")
      }
    }
    UserDefaults.standard.set(timing.joined(separator: " "), forKey: "debug.applyTiming")
    entry.checkpoint = checkpoint
    entry.status = .applied(Self.summaryText(for: results))
    sealedSets[index] = entry
    outcomeNotes.append(Self.modelNote(for: results))
  }

  /// 拒绝整个变更集（不落任何盘）
  func reject(_ changeSetID: UUID) {
    guard let index = sealedSets.firstIndex(where: { $0.id == changeSetID }),
      sealedSets[index].status == .pending
    else { return }
    var entry = sealedSets[index]
    entry.status = .rejected
    entry.checkpoint = nil
    sealedSets[index] = entry
    let paths = entry.set.changes.map(\.path).joined(separator: ", ")
    outcomeNotes.append("The user REJECTED all proposed file changes (\(paths)). Nothing was applied. Ask what to adjust instead of proposing the same thing again.")
  }

  /// 撤销已应用的变更集（检查点回滚：恢复被编辑文件 + 新建项入废纸篓）。
  /// 重启恢复的变更集没有内存检查点——按审查基准重建（编辑文件恢复 baseText，
  /// 新建项按路径入废纸篓）
  func undo(_ changeSetID: UUID) async {
    guard let index = sealedSets.firstIndex(where: { $0.id == changeSetID }),
      case .applied = sealedSets[index].status,
      let environment = applierEnvironment
    else { return }
    var entry = sealedSets[index]
    let checkpoint = entry.checkpoint ?? Self.rebuildCheckpoint(for: entry, environment: environment)
    guard !checkpoint.isEmpty else { return }
    let results = await AIChangeApplier.undo(checkpoint, environment: environment)
    entry.status = .undone
    entry.checkpoint = nil
    sealedSets[index] = entry
    outcomeNotes.append(
      "The user UNDID the previously approved changes (restored \(checkpoint.editedSnapshots.count) files, trashed \(checkpoint.createdPaths.count) created items). \(Self.failureDetail(results))"
    )
  }

  /// 无内存检查点时按审查数据/变更清单重建（重启恢复路径）
  private static func rebuildCheckpoint(
    for entry: SealedChangeSet, environment: AIChangeApplier.Environment
  ) -> AIChangeApplier.BatchCheckpoint {
    guard let root = environment.workspaceRoot() else { return AIChangeApplier.BatchCheckpoint() }
    var point = AIChangeApplier.BatchCheckpoint()
    for change in entry.set.changes {
      guard let resolved = AIToolRegistry.resolveWritePath(
        change.path, root: root, requireExtension: change.kind == .createFolder ? nil : "md")
      else { continue }
      switch change.kind {
      case .createFile, .createFolder:
        point.createdPaths.append(resolved.url)
      case .editFile:
        // 恢复到审查时的基准文本（应用时刻若已漂移，恢复以审查基准为准）
        if let base = entry.reviews[change.id]?.baseText {
          point.editedSnapshots.append(
            AIChangeApplier.BatchCheckpoint.EditedSnapshot(url: resolved.url, beforeText: base))
        }
      }
    }
    return point
  }

  /// 取走自上次发送以来的审查注记（AIChatStore 组装上下文时调用）
  func consumeOutcomeNotes() -> [String] {
    let notes = outcomeNotes
    outcomeNotes = []
    return notes
  }

  // MARK: - 结果文案

  /// UI 摘要（中文，逐文件一行）
  static func summaryText(for results: [AIChangeApplier.FileResult]) -> String {
    results.map { result in
      switch result.outcome {
      case .created: return String(localized: "已新建 \(result.path)")
      case .folderCreated: return String(localized: "已新建文件夹 \(result.path)")
      case .edited(let applied, let skipped):
        return skipped > 0
          ? String(localized: "已修改 \(result.path)（\(applied) 块，\(skipped) 块冲突跳过）")
          : String(localized: "已修改 \(result.path)（\(applied) 块）")
      case .failed(let reason): return String(localized: "失败 \(result.path)：\(reason)")
      }
    }.joined(separator: "\n")
  }

  /// 回传模型的注记（英文；告知真实落盘结果，模型下一轮据实回答）
  static func modelNote(for results: [AIChangeApplier.FileResult]) -> String {
    let parts = results.map { result -> String in
      switch result.outcome {
      case .created: return "created \(result.path)"
      case .folderCreated: return "created folder \(result.path)"
      case .edited(let applied, let skipped):
        return skipped > 0
          ? "edited \(result.path) (\(applied) edits applied, \(skipped) skipped due to conflicts)"
          : "edited \(result.path) (\(applied) edits applied)"
      case .failed(let reason): return "FAILED \(result.path): \(reason)"
      }
    }
    return "The user APPROVED the file changes. Results: \(parts.joined(separator: "; "))."
  }

  private static func failureDetail(_ results: [AIChangeApplier.FileResult]) -> String {
    let failures = results.filter(\.isFailure)
    return failures.isEmpty ? "" : " Issues: " + failures.map { "\($0.path) (\($0.outcome))" }.joined(separator: "; ")
  }
}
