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

  // MARK: - 检查点与撤销回路

  func testUndoRestoresEditsAndTrashesCreated() async throws {
    try? "原始内容".write(to: root.appendingPathComponent("exist.md"), atomically: true, encoding: .utf8)
    let environment = makeEnvironment()
    let editChange = change(.editFile, "exist.md", edits: [
      AIFileChange.TextEdit(oldText: "原始内容", newText: "AI 改写"),
    ])
    let createChange = change(.createFile, "笔记/新文件.md", content: "新内容")

    var checkpoint = await AIChangeApplier.checkpoint(for: editChange, environment: environment)
    checkpoint.merge(await AIChangeApplier.checkpoint(for: createChange, environment: environment))
    _ = await AIChangeApplier.apply(editChange, environment: environment)
    _ = await AIChangeApplier.apply(createChange, environment: environment)
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
