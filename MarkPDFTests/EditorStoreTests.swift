import XCTest

@testable import MarkPDF

/// NFR-5：文件读写失败必须用户可感知（lastError 上报）；自动保存持续失败只提示一次
final class EditorStoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EditorStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func testLoadFileFailureSetsLastError() {
    let store = EditorStore()
    store.loadFile(dir.appendingPathComponent("不存在.md"))
    XCTAssertNotNil(store.lastError, "读取失败必须上报")
    XCTAssertNil(store.currentFileURL, "失败后不应指向该文件")
  }

  func testAutosaveFailureReportsOnceAndRecovers() throws {
    let url = dir.appendingPathComponent("a.md")
    try "初始".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    XCTAssertNil(store.lastError)

    // 目录消失 → 原子写盘必失败 → 首次失败上报
    try FileManager.default.removeItem(at: dir)
    store.contentDidChange("改动 1")
    store.flushPendingSave()
    XCTAssertNotNil(store.lastError, "保存失败必须上报")

    // 持续失败不重复上报（内容每变一次都会重试，防击键级弹窗轰炸）
    store.lastError = nil
    store.contentDidChange("改动 2")
    store.flushPendingSave()
    XCTAssertNil(store.lastError, "持续失败只提示一次")

    // 写盘恢复成功后复位；再次失败会再次上报
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    store.contentDidChange("改动 3")
    store.flushPendingSave()
    XCTAssertFalse(store.hasUnsavedChanges, "恢复后应写盘成功")
    try FileManager.default.removeItem(at: dir)
    store.contentDidChange("改动 4")
    store.flushPendingSave()
    XCTAssertNotNil(store.lastError, "恢复后再失败应再次上报")
  }
}

/// B2 回归：restore 只执行一次——红钮关窗再开时 onAppear 重放不得替换内存中的标签组
/// （快照只有 path 不含正文，整体替换会丢弃 TabGroup 持有的 EditorStore 草稿）
@MainActor
final class TabStoreRestoreTests: XCTestCase {
  func testRestoreRunsOnlyOnce() {
    let store = TabStore()
    let first = [[WorkspaceStateStore.TabState(path: "/tmp/a.md", kind: "markdown")]]
    store.restore(tabStates: first, activeTabPaths: ["/tmp/a.md"], activeGroupIndex: 0)
    let groupsAfterFirst = store.groups
    XCTAssertEqual(groupsAfterFirst.count, 1)
    XCTAssertEqual(groupsAfterFirst[0].tabs.map { $0.url?.lastPathComponent }, ["a.md"])

    // 第二次 restore（onAppear 重放）不得替换 groups
    let second = [[WorkspaceStateStore.TabState(path: "/tmp/b.md", kind: "markdown")]]
    store.restore(tabStates: second, activeTabPaths: ["/tmp/b.md"], activeGroupIndex: 0)
    XCTAssertEqual(store.groups.map(\.id), groupsAfterFirst.map(\.id), "重复 restore 不应替换标签组")
    XCTAssertEqual(store.groups[0].tabs.map { $0.url?.lastPathComponent }, ["a.md"])
  }
}

/// B3 回归：文件被移入废纸篓 → 标签转草稿（清橙点、取消挂起保存）；
/// 从废纸篓放回原位后重新点击 → 重载磁盘内容恢复落盘能力
@MainActor
final class TrashRestoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TrashRestoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func testFileWasTrashedClearsUnsavedAndCancelsPendingSave() throws {
    let url = dir.appendingPathComponent("a.md")
    try "初始".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    store.contentDidChange("未落盘改动")
    XCTAssertTrue(store.hasUnsavedChanges)

    store.fileWasTrashed(url)
    XCTAssertNil(store.currentFileURL)
    XCTAssertFalse(store.hasUnsavedChanges, "转草稿后橙点应熄灭")

    // 挂起的自动保存已取消：flush 也不得写回磁盘
    store.flushPendingSave()
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "初始")
  }

  func testReopenAfterTrashRestoreReloadsFile() throws {
    let url = dir.appendingPathComponent("b.md")
    try "磁盘 v1".write(to: url, atomically: true, encoding: .utf8)
    let group = TabGroup()
    group.open(FileNode(id: url, name: "b.md", kind: .markdown))
    let tab = try XCTUnwrap(group.tabs.first)
    let store = group.editorStore(for: tab)
    XCTAssertEqual(store.text, "磁盘 v1")

    // 移入废纸篓：转草稿
    group.fileWasTrashed(url)
    XCTAssertNil(store.currentFileURL)

    // 仍在废纸篓（原路径不存在）：命中缓存不得重载（避免「无法打开」误报）
    try FileManager.default.removeItem(at: url)
    _ = group.editorStore(for: tab)
    XCTAssertNil(store.currentFileURL, "文件未放回原位不应重载")

    // 从废纸篓放回原位（内容以磁盘为准）：重新点击 → 重载并恢复落盘能力
    try "磁盘 v2".write(to: url, atomically: true, encoding: .utf8)
    _ = group.editorStore(for: tab)
    XCTAssertEqual(store.currentFileURL, url)
    XCTAssertEqual(store.text, "磁盘 v2")

    // 恢复后自动保存可正常落盘
    store.contentDidChange("磁盘 v2 追加")
    store.flushPendingSave()
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "磁盘 v2 追加")
  }
}
