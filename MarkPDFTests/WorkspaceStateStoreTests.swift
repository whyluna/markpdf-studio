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

  /// 端到端：完全按 ContentView 接线（onStructureChange → tabsDidChange），
  /// 用户经 TabStore.open 打开文件后，槽位必须记录到真实文件标签（而非草稿）
  @MainActor
  func testOpeningFileRecordsIntoSlot() throws {
    let store = WorkspaceStateStore(defaults: defaults)
    let tabStore = TabStore()
    store.workspaceDidChange(root: rootA, collapsedFolders: [])
    // 与 ContentView.onAppear 一致的接线
    tabStore.onStructureChange = { [weak tabStore] in
      guard let tabStore else { return }
      store.tabsDidChange(groups: tabStore.groups, activeGroupID: tabStore.activeGroupID)
    }

    tabStore.open(FileNode(id: file1, name: "a.md", kind: .markdown))
    store.flush()

    let data = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot.v1"))
    let snapshot = try JSONDecoder().decode(WorkspaceStateStore.Snapshot.self, from: data)
    let key = rootA.standardizedFileURL.path
    let paths = snapshot.workspaces[key]?.groups.flatMap { $0 }.compactMap(\.path)
    XCTAssertEqual(paths, [file1.path], "打开文件后槽位应记录真实文件标签")
  }

  /// 切换工作区不得清掉旧槽（实机 bug 回归）：切换编排期间 root 仍是旧工作区（异步扫描未完成），
  /// collapsedFolders 赋值等路过事件会以旧 root 触发 workspaceDidChange——必须把这类事件挡在门外，
  /// 否则槽位指针被拉回旧工作区，随后的 replaceAll 把空白草稿写进旧槽、真实标签被覆盖丢失
  @MainActor
  func testSwitchDoesNotWipeOldSlotViaStaleWatcherEvent() throws {
    // 沙盒测试运行器只允许在容器临时目录下建目录（/tmp 根会被拒）
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("WSSwitch-\(UUID().uuidString)", isDirectory: true)
    let rootA = base.appendingPathComponent("ws-a", isDirectory: true)
    let rootB = base.appendingPathComponent("ws-b", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: rootB, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let store = WorkspaceStateStore(defaults: defaults)
    let tabStore = TabStore()
    let ws = WorkspaceStore(watcher: NoopWatcher())
    // 完整 App 接线（ContentView 同款两条链）
    tabStore.onStructureChange = { [weak tabStore] in
      guard let tabStore else { return }
      store.tabsDidChange(groups: tabStore.groups, activeGroupID: tabStore.activeGroupID)
    }
    ws.onStateChange = { [weak ws] in
      store.workspaceDidChange(root: ws?.root?.id, collapsedFolders: ws?.collapsedFolders ?? [])
    }

    // 打开 A（含异步扫描置 root）并开一个真实文件标签
    store.switchWorkspace(to: rootA, workspaceStore: ws, tabStore: tabStore)
    let deadline = Date().addingTimeInterval(5)
    while ws.root == nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertNotNil(ws.root)
    tabStore.open(FileNode(id: file1, name: "a.md", kind: .markdown))

    // 切到 B：此间 collapsedFolders 赋值会以旧 root(A) 触发路过事件
    store.switchWorkspace(to: rootB, workspaceStore: ws, tabStore: tabStore)
    store.flush()

    let data = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot.v1"))
    let snapshot = try JSONDecoder().decode(WorkspaceStateStore.Snapshot.self, from: data)
    XCTAssertEqual(
      snapshot.workspaces[rootA.standardizedFileURL.path]?.groups.flatMap { $0 }.compactMap(\.path),
      [file1.path],
      "旧工作区槽位必须保留真实标签，不得被切换期间的路过事件覆盖"
    )
    XCTAssertEqual(store.currentRootPath, rootB.standardizedFileURL.path)

    // 切回 A：真实标签应恢复（而非只剩空白草稿）
    store.switchWorkspace(to: rootA, workspaceStore: ws, tabStore: tabStore)
    XCTAssertTrue(
      tabStore.groups[0].tabs.contains(where: { $0.url == file1 }),
      "切回应恢复旧工作区的真实标签"
    )
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
