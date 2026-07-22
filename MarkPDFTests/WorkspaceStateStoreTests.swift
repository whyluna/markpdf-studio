import XCTest
@testable import MarkPDF

/// 工作区状态持久化（FR-1.6）：快照记录/恢复、兼容解码、损坏回退
final class WorkspaceStateStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    // 固定 suite 名 + 用前清场：避免 UUID 随机名在磁盘堆积 plist
    suiteName = "WorkspaceStateStoreTests"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    super.tearDown()
  }

  private let file1 = URL(fileURLWithPath: "/tmp/ws/a.md")
  private let file2 = URL(fileURLWithPath: "/tmp/ws/b.pdf")

  // MARK: - 光标行

  @MainActor
  func testCursorLineRoundTrip() {
    let store = WorkspaceStateStore(defaults: defaults)
    XCTAssertNil(store.cursorLine(for: file1))
    store.recordCursor(url: file1, line: 42)
    store.flush()
    let reopened = WorkspaceStateStore(defaults: defaults)
    XCTAssertEqual(reopened.cursorLine(for: file1), 42)
  }

  // MARK: - 标签快照 → TabStore 恢复

  @MainActor
  private func makeTabStoreWithTwoGroups() -> TabStore {
    let tabStore = TabStore()
    let first = tabStore.groups[0]
    first.tabs = [
      EditorTab(url: file1, kind: .markdown),
      EditorTab(url: file2, kind: .pdf),
    ]
    first.activeTabID = file2.path
    tabStore.toggleSplit()
    tabStore.groups[1].tabs = [EditorTab(url: file1, kind: .markdown)]
    tabStore.activeGroupID = tabStore.groups[1].id
    return tabStore
  }

  @MainActor
  func testTabsSnapshotAndRestore() {
    let source = makeTabStoreWithTwoGroups()
    let store = WorkspaceStateStore(defaults: defaults)
    // 分槽模型：先建立当前工作区，标签快照才入槽
    store.workspaceDidChange(root: URL(fileURLWithPath: "/tmp/ws"), collapsedFolders: [])
    store.tabsDidChange(groups: source.groups, activeGroupID: source.activeGroupID)
    store.flush()

    // 新实例 + 新 TabStore（模拟重启）恢复（经 lastRootPath 槽位）
    let reopened = WorkspaceStateStore(defaults: defaults)
    let target = TabStore()
    reopened.restoreTabs(into: target)

    XCTAssertEqual(target.groups.count, 2)
    XCTAssertEqual(target.groups[0].tabs.map(\.url), [file1, file2])
    XCTAssertEqual(target.groups[0].tabs.map(\.kind), [.markdown, .pdf])
    XCTAssertEqual(target.groups[0].activeTabID, file2.path)
    XCTAssertEqual(target.groups[1].tabs.count, 1)
    XCTAssertEqual(target.activeGroupID, target.groups[1].id)
  }

  @MainActor
  func testRestoreEmptySnapshotKeepsDefaultDraft() {
    let store = WorkspaceStateStore(defaults: defaults)
    let target = TabStore()
    store.restoreTabs(into: target)
    XCTAssertEqual(target.groups.count, 1)
    XCTAssertEqual(target.groups[0].tabs.count, 1)
    XCTAssertTrue(target.groups[0].tabs[0].isDraft)
  }

  @MainActor
  func testRestoreDropsEmptyGroups() {
    let store = WorkspaceStateStore(defaults: defaults)
    // 快照含一个空组（退出时残留的空白分栏）
    let tabStore = TabStore()
    tabStore.restore(
      tabStates: [
        [WorkspaceStateStore.TabState(path: file1.path, kind: "markdown")],
        [],
      ],
      activeTabPaths: [file1.path, nil],
      activeGroupIndex: 0
    )
    XCTAssertEqual(tabStore.groups.count, 1)
    _ = store
  }

  // MARK: - 工作区快照

  @MainActor
  func testWorkspaceCollapsedFoldersRoundTrip() throws {
    let store = WorkspaceStateStore(defaults: defaults)
    store.workspaceDidChange(
      root: URL(fileURLWithPath: "/tmp/ws"),
      collapsedFolders: [URL(fileURLWithPath: "/tmp/ws/sub")]
    )
    store.flush()
    let data = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot.v1"))
    let snapshot = try JSONDecoder().decode(WorkspaceStateStore.Snapshot.self, from: data)
    let key = URL(fileURLWithPath: "/tmp/ws").standardizedFileURL.path
    XCTAssertEqual(snapshot.workspaces[key]?.collapsedFolders, ["/tmp/ws/sub"])
    XCTAssertEqual(snapshot.lastRootPath, key)
  }

  @MainActor
  func testCorruptSnapshotFallsBackToEmpty() {
    defaults.set(Data([0xFF, 0x00, 0x01]), forKey: "workspaceSnapshot.v1")
    let store = WorkspaceStateStore(defaults: defaults)
    let target = TabStore()
    store.restoreTabs(into: target)
    XCTAssertEqual(target.groups.count, 1)
    XCTAssertTrue(target.groups[0].tabs[0].isDraft)
  }

  // MARK: - 切换工作区（标签按工作区隔离）

  /// 不做任何监听的 FileWatcher（切换流程无需外部变更重扫）
  private final class NoopWatcher: FileWatcher {
    func startWatching(url: URL, onChange: @escaping () -> Void) {}
    func stopWatching() {}
  }

  private let rootA = URL(fileURLWithPath: "/tmp/ws-a")
  private let rootB = URL(fileURLWithPath: "/tmp/ws-b")
  private let bFile = URL(fileURLWithPath: "/tmp/ws-b/b.md")

  @MainActor
  func testSwitchWorkspaceIsolatesAndRestoresTabs() {
    let store = WorkspaceStateStore(defaults: defaults)
    let tabStore = TabStore()
    let ws = WorkspaceStore(watcher: NoopWatcher())

    // 工作区 A：开两个标签并记录现场
    store.workspaceDidChange(root: rootA, collapsedFolders: [])
    tabStore.groups[0].tabs = [EditorTab(url: file1, kind: .markdown), EditorTab(url: file2, kind: .pdf)]
    store.tabsDidChange(groups: tabStore.groups, activeGroupID: tabStore.activeGroupID)

    // 切到 B（无记录）：A 的标签全部消失，重置为空白草稿
    store.switchWorkspace(to: rootB, workspaceStore: ws, tabStore: tabStore)
    XCTAssertEqual(tabStore.groups.count, 1)
    XCTAssertEqual(tabStore.groups[0].tabs.count, 1)
    XCTAssertTrue(tabStore.groups[0].tabs[0].isDraft)

    // B 里开一个标签并记录
    tabStore.groups[0].tabs = [EditorTab(url: bFile, kind: .markdown)]
    store.tabsDidChange(groups: tabStore.groups, activeGroupID: tabStore.activeGroupID)

    // 切回 A：恢复 A 自己的两个标签，B 的标签不出现
    store.switchWorkspace(to: rootA, workspaceStore: ws, tabStore: tabStore)
    XCTAssertEqual(tabStore.groups[0].tabs.map(\.url), [file1, file2])

    // 再切回 B：恢复 B 自己的标签
    store.switchWorkspace(to: rootB, workspaceStore: ws, tabStore: tabStore)
    XCTAssertEqual(tabStore.groups[0].tabs.map(\.url), [bFile])
  }

  @MainActor
  func testSwitchWorkspaceSameRootIsNoOp() {
    let store = WorkspaceStateStore(defaults: defaults)
    let tabStore = TabStore()
    let ws = WorkspaceStore(watcher: NoopWatcher())
    store.workspaceDidChange(root: rootA, collapsedFolders: [])
    tabStore.groups[0].tabs = [EditorTab(url: file1, kind: .markdown)]

    // 重开当前工作区：标签原样保留（不重置、不清空）
    store.switchWorkspace(to: rootA, workspaceStore: ws, tabStore: tabStore)
    XCTAssertEqual(tabStore.groups[0].tabs.map(\.url), [file1])
  }

  @MainActor
  func testLegacySnapshotMigratesIntoLastRootSlot() throws {
    // 真实目录才能创建/解析 security-scoped bookmark
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WSLegacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmark = try root.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
    )
    // v1 格式快照：全局 groups + rootBookmark，无 workspaces 分槽（Data 以 base64 写入，对齐 Codable）
    let legacy: [String: Any] = [
      "rootBookmark": bookmark.base64EncodedString(),
      "groups": [[["path": file1.path, "kind": "markdown"]]],
      "activeTabs": [file1.path],
      "activeGroup": 0,
      "collapsedFolders": ["/tmp/ws/sub"],
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "workspaceSnapshot.v1")

    let store = WorkspaceStateStore(defaults: defaults)
    store.restoreWorkspace(into: WorkspaceStore(watcher: NoopWatcher()))
    let tabStore = TabStore()
    store.restoreTabs(into: tabStore)

    // 旧全局标签已归入该工作区槽位并可恢复
    XCTAssertEqual(tabStore.groups[0].tabs.map(\.url), [file1])
  }
}
