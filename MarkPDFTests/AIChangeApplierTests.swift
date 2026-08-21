import XCTest
@testable import MarkPDF

/// 变更应用引擎（FR-AI.5）：三分支路由 + 检查点撤销回路（临时目录 + 替身环境）
@MainActor
final class AIChangeApplierTests: XCTestCase {
  private var root: URL!
  private var trashDir: URL!
  private var openedTabs: [URL] = []
  private var refreshCount = 0
  private var trashedNotifications: [URL] = []

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIApplyTests-\(UUID().uuidString)")
    trashDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIApplyTests-trash-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: trashDir)
    super.tearDown()
  }

  /// 生产形态的环境替身：kernel 恒不可用（走 persistViaStore 回退——测试内核不存在）
  private func makeEnvironment(store: EditorStore? = nil, storeURL: URL? = nil) -> AIChangeApplier.Environment {
    AIChangeApplier.Environment(
      findEditorStore: { [weak store] url in
        guard let store, let storeURL, WindowCoordinator.normalize(url) == WindowCoordinator.normalize(storeURL) else { return nil }
        return store
      },
      applyViaKernel: { _, text, completion in completion(false) },
      persistViaStore: { store, text in
        store.contentDidChange(text)
        store.flushPendingSave()
      },
      workspaceRoot: { [weak self] in self?.root },
      openTab: { [weak self] url in self?.openedTabs.append(url) },
      refreshTree: { [weak self] in self?.refreshCount += 1 },
      trashFile: { [weak self] url in
        guard let self else { return false }
        let target = self.trashDir.appendingPathComponent(url.lastPathComponent)
        do {
          try FileManager.default.moveItem(at: url, to: target)
          return true
        } catch { return false }
      },
      notifyTrashed: { [weak self] url in self?.trashedNotifications.append(url) }
    )
  }

  private func change(
    _ kind: AIFileChange.Kind, _ path: String, content: String = "", edits: [AIFileChange.TextEdit] = []
  ) -> AIFileChange {
    AIFileChange(kind: kind, path: path, content: content, edits: edits)
  }

  private func diskText(_ relative: String) -> String? {
    try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
  }

  // MARK: - 新建

  func testCreateFileWritesContentAndOpensTab() async {
    let result = await AIChangeApplier.apply(
      change(.createFile, "笔记/读书笔记.md", content: "# 标题\n\n内容"),
      environment: makeEnvironment()
    )
    XCTAssertEqual(result.outcome, .created)
    XCTAssertEqual(diskText("笔记/读书笔记.md"), "# 标题\n\n内容", "含中间父目录创建")
    XCTAssertEqual(openedTabs, [root.appendingPathComponent("笔记/读书笔记.md")], "新建后开标签")
    XCTAssertGreaterThanOrEqual(refreshCount, 1)
  }

  func testCreateFileFailsWhenExists() async {
    try? "已有".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    let result = await AIChangeApplier.apply(
      change(.createFile, "a.md", content: "新"), environment: makeEnvironment()
    )
    XCTAssertTrue(result.isFailure)
    XCTAssertEqual(diskText("a.md"), "已有", "不覆盖既有文件")
  }

  func testCreateFolderFailsWhenTargetAppearedBeforeApproval() async {
    let folder = root.appendingPathComponent("用户目录")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? "用户内容".write(
      to: folder.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)

    let result = await AIChangeApplier.apply(
      change(.createFolder, "用户目录"), environment: makeEnvironment())

    XCTAssertTrue(result.isFailure, "已存在的最终目录不能被误报为本批新建")
    XCTAssertEqual(diskText("用户目录/keep.md"), "用户内容")
  }

  // MARK: - 编辑：未打开（磁盘分支）

  func testEditUnopenedFileWritesDisk() async {
    try? "# 旧标题\n\n正文".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    let result = await AIChangeApplier.apply(
      change(.editFile, "note.md", edits: [
        AIFileChange.TextEdit(oldText: "# 旧标题", newText: "# 新标题"),
      ]),
      environment: makeEnvironment()
    )
    XCTAssertEqual(result.outcome, .edited(appliedEdits: 1, skippedEdits: 0))
    XCTAssertEqual(diskText("note.md"), "# 新标题\n\n正文")
  }

  /// 提案后文件被外部改动：冲突块跳过、可应用块照常应用（不整批失败）
  func testEditConflictSkipsStaleEditsOnly() async {
    try? "版本 A\n\n版本 B".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    let result = await AIChangeApplier.apply(
      change(.editFile, "note.md", edits: [
        AIFileChange.TextEdit(oldText: "版本 X", newText: "X 改"),  // 磁盘已无此文本
        AIFileChange.TextEdit(oldText: "版本 B", newText: "版本 B+"),
      ]),
      environment: makeEnvironment()
    )
    XCTAssertEqual(result.outcome, .edited(appliedEdits: 1, skippedEdits: 1))
    XCTAssertEqual(diskText("note.md"), "版本 A\n\n版本 B+")
  }

  // MARK: - 编辑：已打开（编辑器分支，内核不可用回退落盘）

  func testEditOpenStoreAppliesToLiveText() async throws {
    let url = root.appendingPathComponent("live.md")
    try? "# 草稿\n\n未落盘的新段落".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    let loaded = await waitUntil { store.currentFileURL == url }
    XCTAssertTrue(loaded)

    let result = await AIChangeApplier.apply(
      change(.editFile, "live.md", edits: [
        AIFileChange.TextEdit(oldText: "# 草稿", newText: "# 定稿"),
      ]),
      environment: makeEnvironment(store: store, storeURL: url)
    )
    XCTAssertEqual(result.outcome, .edited(appliedEdits: 1, skippedEdits: 0))
    // 编辑器内存与磁盘一致（回退路径 contentDidChange + flush 落盘）
    XCTAssertEqual(store.text, "# 定稿\n\n未落盘的新段落")
    XCTAssertEqual(diskText("live.md"), "# 定稿\n\n未落盘的新段落")
  }

  /// 活体 Web 内核成功后也必须立即推进 Native store；不能只等 Web 侧防抖的
  /// contentChanged，否则卡片先完成、当前标签仍显示旧文，切换标签后才收敛。
  func testSuccessfulKernelImmediatelySynchronizesNativeStoreAndDisk() async throws {
    let url = root.appendingPathComponent("visible.md")
    try "旧内容".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    let loaded = await waitUntil { store.currentFileURL == url }
    XCTAssertTrue(loaded)
    var kernelText: String?
    var synchronizedCount = 0
    let environment = AIChangeApplier.Environment(
      findEditorStore: { candidate in
        WindowCoordinator.normalize(candidate) == WindowCoordinator.normalize(url) ? store : nil
      },
      applyViaKernel: { _, text, completion in
        kernelText = text
        completion(true)
      },
      persistViaStore: { store, text in
        synchronizedCount += 1
        store.contentDidChange(text)
        store.flushPendingSave()
      },
      workspaceRoot: { self.root }
    )

    let result = await AIChangeApplier.apply(
      change(.editFile, "visible.md", edits: [
        AIFileChange.TextEdit(oldText: "旧内容", newText: "立即刷新"),
      ]),
      environment: environment)

    XCTAssertEqual(result.outcome, .edited(appliedEdits: 1, skippedEdits: 0))
    XCTAssertEqual(kernelText, "立即刷新", "活体内核仍保留单事务替换/撤销语义")
    XCTAssertEqual(synchronizedCount, 1, "内核成功后也同步 Native 状态")
    XCTAssertEqual(store.text, "立即刷新", "apply 返回前当前标签绑定已是新内容")
    XCTAssertEqual(diskText("visible.md"), "立即刷新")
  }

  // MARK: - 检查点与撤销回路

  func testUndoRestoresEditsAndTrashesCreated() async throws {
    try? "原始内容".write(to: root.appendingPathComponent("exist.md"), atomically: true, encoding: .utf8)
    let environment = makeEnvironment()
    let editChange = change(.editFile, "exist.md", edits: [
      AIFileChange.TextEdit(oldText: "原始内容", newText: "AI 改写"),
    ])
    let createChange = change(.createFile, "笔记/新文件.md", content: "新内容")

    var checkpoint = AIChangeApplier.BatchCheckpoint()
    var editCheckpoint = await AIChangeApplier.checkpoint(for: editChange, environment: environment)
    let editResult = await AIChangeApplier.apply(editChange, environment: environment)
    editCheckpoint.retainAppliedResult(editResult)
    checkpoint.merge(editCheckpoint)
    var createCheckpoint = await AIChangeApplier.checkpoint(for: createChange, environment: environment)
    let createResult = await AIChangeApplier.apply(createChange, environment: environment)
    createCheckpoint.retainAppliedResult(createResult)
    checkpoint.merge(createCheckpoint)
    XCTAssertEqual(diskText("exist.md"), "AI 改写")
    XCTAssertNotNil(diskText("笔记/新文件.md"))

    _ = await AIChangeApplier.undo(checkpoint, environment: environment)
    XCTAssertEqual(diskText("exist.md"), "原始内容", "被编辑文件恢复变更前内容")
    XCTAssertNil(diskText("笔记/新文件.md"), "新建文件入废纸篓（测试替身为移动到垃圾目录）")
    XCTAssertTrue(
      trashDir.appendingPathComponent("新文件.md").hasDirectoryPath
        || FileManager.default.fileExists(atPath: trashDir.appendingPathComponent("新文件.md").path)
    )
    XCTAssertEqual(trashedNotifications.count, 1, "入废纸篓联动标签转草稿通知")
  }

  func testUndoProtectsEditsMadeAfterAIApplication() async {
    let url = root.appendingPathComponent("later.md")
    try? "原文".write(to: url, atomically: true, encoding: .utf8)
    let environment = makeEnvironment()
    let edit = change(.editFile, "later.md", edits: [
      AIFileChange.TextEdit(oldText: "原文", newText: "AI 改写"),
    ])
    var checkpoint = await AIChangeApplier.checkpoint(for: edit, environment: environment)
    let result = await AIChangeApplier.apply(edit, environment: environment)
    checkpoint.retainAppliedResult(result)
    try? "AI 改写\n用户后续输入".write(to: url, atomically: true, encoding: .utf8)

    let undo = await AIChangeApplier.undo(checkpoint, environment: environment)

    XCTAssertEqual(diskText("later.md"), "AI 改写\n用户后续输入", "撤销不得覆盖应用后的用户编辑")
    XCTAssertFalse(undo.remainingCheckpoint.isEmpty, "冲突项保留检查点供用户处理后重试")
    XCTAssertTrue(undo.results.contains(where: \.isFailure))
  }

  func testUndoDoesNotTrashModifiedCreatedFileOrNonemptyFolder() async {
    let environment = makeEnvironment()
    let file = change(.createFile, "new.md", content: "AI 内容")
    let folder = change(.createFolder, "new-folder")
    var checkpoint = AIChangeApplier.BatchCheckpoint()
    var fileCheckpoint = await AIChangeApplier.checkpoint(for: file, environment: environment)
    let fileResult = await AIChangeApplier.apply(file, environment: environment)
    fileCheckpoint.retainAppliedResult(fileResult)
    checkpoint.merge(fileCheckpoint)
    var folderCheckpoint = await AIChangeApplier.checkpoint(for: folder, environment: environment)
    let folderResult = await AIChangeApplier.apply(folder, environment: environment)
    folderCheckpoint.retainAppliedResult(folderResult)
    checkpoint.merge(folderCheckpoint)
    try? "用户修改".write(to: root.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
    try? "用户文件".write(
      to: root.appendingPathComponent("new-folder/keep.md"), atomically: true, encoding: .utf8)

    let undo = await AIChangeApplier.undo(checkpoint, environment: environment)

    XCTAssertEqual(diskText("new.md"), "用户修改")
    XCTAssertEqual(diskText("new-folder/keep.md"), "用户文件")
    XCTAssertEqual(undo.remainingCheckpoint.createdSnapshots.count, 2)
    XCTAssertTrue(trashedNotifications.isEmpty, "校验失败前不能先把打开标签转草稿")
  }

  // MARK: - 工具

  private func waitUntil(
    timeout: TimeInterval = 3, _ condition: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }
}
