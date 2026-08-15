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

  // MARK: - 根改名/移动的槽位迁移

  /// 纯函数迁移：槽位键/书签键/最后根/窗口清单换键；槽位内路径与光标行按前缀平移
  func testMigrateRootSlotShiftsKeysAndInnerPaths() {
    let oldPath = "/ws/old-root"
    let newPath = "/ws/new-root"
    var state = WorkspaceSnapshotStore.Snapshot()
    var ws = WorkspaceSnapshotStore.WorkspaceSnapshot()
    ws.collapsedFolders = ["\(oldPath)/sub", "/elsewhere/x"]
    ws.groups = [
      [WorkspaceSnapshotStore.TabState(path: "\(oldPath)/a.md", kind: "markdown")],
    ]
    ws.activeTabs = ["\(oldPath)/a.md"]
    state.workspaces[oldPath] = ws
    state.bookmarks[oldPath] = Data("bm".utf8)
    state.lastRootPath = oldPath
    state.openWindowRoots = [oldPath, "/ws/other"]
    state.cursorLines = ["\(oldPath)/a.md": 7, "/ws/other/b.md": 3]

    WorkspaceStateStore.migrateRootSlot(&state, from: oldPath, to: newPath)

    XCTAssertNil(state.workspaces[oldPath])
    XCTAssertEqual(state.workspaces[newPath]?.collapsedFolders, ["\(newPath)/sub", "/elsewhere/x"])
    XCTAssertEqual(state.workspaces[newPath]?.groups.first?.first?.path, "\(newPath)/a.md")
    XCTAssertEqual(state.workspaces[newPath]?.activeTabs, ["\(newPath)/a.md"])
    XCTAssertEqual(state.bookmarks[newPath], Data("bm".utf8))
    XCTAssertNil(state.bookmarks[oldPath])
    XCTAssertEqual(state.lastRootPath, newPath)
    XCTAssertEqual(state.openWindowRoots, [newPath, "/ws/other"])
    XCTAssertEqual(state.cursorLines, ["\(newPath)/a.md": 7, "/ws/other/b.md": 3])
  }

  /// 端到端：Finder 里给根文件夹改名 → 安全书签仍能解析（按文件 ID 追踪）→
  /// 恢复时检测「解析路径 ≠ 存储键」并触发迁移钩子；新根下光标行可读
  @MainActor
  func testRestoreMigratesSlotWhenRootRenamedExternally() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("RootRename.\(UUID().uuidString)")
    let oldDir = parent.appendingPathComponent("old-root")
    try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let mdFile = oldDir.appendingPathComponent("笔记.md")
    try "x".write(to: mdFile, atomically: true, encoding: .utf8)
    // 书签解析的规范形（/var → /private/var）：存储键与解析结果同口径，改名是唯一变量
    let oldPath = oldDir.resolvingSymlinksInPath().path
    let bookmark = try oldDir.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

    var snapshot = WorkspaceSnapshotStore.Snapshot()
    snapshot.bookmarks[oldPath] = bookmark
    snapshot.lastRootPath = oldPath
    snapshot.openWindowRoots = [oldPath]
    snapshot.cursorLines = ["\(oldPath)/笔记.md": 7]
    defaults.set(try JSONEncoder().encode(snapshot), forKey: "workspaceSnapshot.v1")

    let newDir = parent.appendingPathComponent("new-root")
    try FileManager.default.moveItem(at: oldDir, to: newDir)
    let newPath = newDir.resolvingSymlinksInPath().path

    let stateStore = WorkspaceStateStore(defaults: defaults)
    var moved: (String, String)?
    stateStore.onWorkspaceRootMoved = { moved = ($0, $1) }
    stateStore.restoreWorkspace(into: WorkspaceStore(), rootPath: oldPath)

    XCTAssertEqual(moved?.0, oldPath, "迁移钩子带回旧键")
    XCTAssertEqual(moved?.1, newPath, "迁移钩子带回解析出的新路径")
    XCTAssertEqual(stateStore.currentRootPath, newPath, "当前根已是新路径")
    XCTAssertEqual(
      stateStore.cursorLine(for: newDir.appendingPathComponent("笔记.md")), 7,
      "光标行随根平移")
  }


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

  // MARK: - AI 助手显隐随工作区（FR-AI.2）

  @MainActor
  func testAIAssistantVisibilityPersistsPerWorkspace() {
    let root = URL(fileURLWithPath: "/tmp/ws")
    let store = WorkspaceStateStore(defaults: defaults)
    store.workspaceDidChange(root: root, collapsedFolders: [], aiAssistantVisible: true)
    store.flush()

    // 重启后切换到该工作区 → 显隐恢复
    let reopened = WorkspaceStateStore(defaults: defaults)
    let workspaceStore = WorkspaceStore()
    let tabStore = TabStore()
    reopened.switchWorkspace(to: root, workspaceStore: workspaceStore, tabStore: tabStore)
    XCTAssertTrue(workspaceStore.isAIAssistantPresented)

    // 无记录的工作区 → 默认关闭
    reopened.switchWorkspace(to: URL(fileURLWithPath: "/tmp/other"), workspaceStore: workspaceStore, tabStore: tabStore)
    XCTAssertFalse(workspaceStore.isAIAssistantPresented)
  }

  /// 旧快照（无 aiAssistantVisible 键）可解码且默认关
  @MainActor
  func testLegacySnapshotWithoutAIVisibilityDecodes() throws {
    let legacy = #"{"lastRootPath":"/tmp/ws","workspaces":{"/tmp/ws":{"collapsedFolders":[],"groups":[],"activeTabs":[],"activeGroup":0}}}"#
    defaults.set(Data(legacy.utf8), forKey: "workspaceSnapshot.v1")
    let store = WorkspaceStateStore(defaults: defaults)
    let workspaceStore = WorkspaceStore()
    let tabStore = TabStore()
    store.switchWorkspace(to: URL(fileURLWithPath: "/tmp/ws2"), workspaceStore: workspaceStore, tabStore: tabStore)
    XCTAssertFalse(workspaceStore.isAIAssistantPresented)
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

  // MARK: - 多窗口共享快照存储（v1.5）

  /// 两个窗口 facade 共享一个快照存储：各自的槽位/光标互不覆盖，一次落盘全量保留
  @MainActor
  func testTwoFacadesShareSnapshotStoreWithoutOverwriting() {
    let shared = WorkspaceSnapshotStore(defaults: defaults)
    let windowA = WorkspaceStateStore(snapshotStore: shared)
    let windowB = WorkspaceStateStore(snapshotStore: shared)
    let rootA = URL(fileURLWithPath: "/tmp/wsA")
    let rootB = URL(fileURLWithPath: "/tmp/wsB")
    windowA.workspaceDidChange(root: rootA, collapsedFolders: [URL(fileURLWithPath: "/tmp/wsA/sub")])
    windowB.workspaceDidChange(root: rootB, collapsedFolders: [])
    windowA.recordCursor(url: file1, line: 7)
    shared.flush()

    let reopened = WorkspaceSnapshotStore(defaults: defaults)
    let keyA = rootA.standardizedFileURL.path
    let keyB = rootB.standardizedFileURL.path
    XCTAssertNotNil(reopened.state.workspaces[keyA], "窗口 A 槽位保留")
    XCTAssertNotNil(reopened.state.workspaces[keyB], "窗口 B 槽位保留")
    XCTAssertEqual(reopened.state.workspaces[keyA]?.collapsedFolders, ["/tmp/wsA/sub"])
    XCTAssertEqual(reopened.state.cursorLines[file1.path], 7)
    // 每窗口自己的 currentRootPath 独立（窗口态不共享）
    XCTAssertEqual(windowA.currentRootPath, keyA)
    XCTAssertEqual(windowB.currentRootPath, keyB)
  }

  // MARK: - 多工作区书签与窗口恢复（v1.5）

  /// 逐工作区书签：切换工作区不再覆盖上一个的书签（多窗口重启恢复依赖）
  @MainActor
  func testBookmarksKeptPerWorkspace() throws {
    let shared = WorkspaceSnapshotStore(defaults: defaults)
    let store = WorkspaceStateStore(snapshotStore: shared)
    let rootA = FileManager.default.temporaryDirectory
      .appendingPathComponent("wsA-\(UUID().uuidString)")
    let rootB = FileManager.default.temporaryDirectory
      .appendingPathComponent("wsB-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: rootA)
      try? FileManager.default.removeItem(at: rootB)
    }

    store.workspaceDidChange(root: rootA, collapsedFolders: [])
    store.workspaceDidChange(root: rootB, collapsedFolders: [])
    XCTAssertNotNil(shared.state.bookmarks[rootA.standardizedFileURL.path], "旧工作区书签不被覆盖")
    XCTAssertNotNil(shared.state.bookmarks[rootB.standardizedFileURL.path])
  }

  /// 旧单书签快照解码时迁入多书签表（键 = lastRootPath）
  @MainActor
  func testLegacySingleBookmarkMigratesIntoBookmarksMap() throws {
    var legacy = WorkspaceSnapshotStore.Snapshot()
    legacy.lastRootPath = "/tmp/ws"
    legacy.rootBookmark = Data("fake-bookmark".utf8)
    defaults.set(try JSONEncoder().encode(legacy), forKey: "workspaceSnapshot.v1")

    let store = WorkspaceSnapshotStore(defaults: defaults)
    XCTAssertEqual(store.state.bookmarks["/tmp/ws"], Data("fake-bookmark".utf8))
    XCTAssertNil(store.state.rootBookmark, "迁移后不再写单书签字段")
  }

  /// 启动恢复清单：上次开着的窗口优先；空列表回退最后工作区；无书签的剔除
  func testRootsToRestoreMatrix() {
    let bookmarks = ["/a": Data(), "/b": Data()]
    XCTAssertEqual(
      WorkspaceSnapshotStore.rootsToRestore(openWindowRoots: ["/a", "/b"], lastRootPath: "/b", bookmarks: bookmarks),
      ["/a", "/b"],
      "按上次窗口顺序恢复"
    )
    XCTAssertEqual(
      WorkspaceSnapshotStore.rootsToRestore(openWindowRoots: [], lastRootPath: "/b", bookmarks: bookmarks),
      ["/b"],
      "空列表（全部关窗后退出/旧快照）回退最后工作区"
    )
    XCTAssertEqual(
      WorkspaceSnapshotStore.rootsToRestore(openWindowRoots: ["/a", "/missing", "/a"], lastRootPath: nil, bookmarks: bookmarks),
      ["/a"],
      "无书签的剔除（授权失效开不了）+ 去重"
    )
    XCTAssertTrue(
      WorkspaceSnapshotStore.rootsToRestore(openWindowRoots: [], lastRootPath: nil, bookmarks: bookmarks).isEmpty
    )
  }

  @MainActor
  func testOpenWindowRootsRoundTrip() throws {
    let store = WorkspaceSnapshotStore(defaults: defaults)
    store.recordOpenWindowRoots(["/a", "/b"])
    store.flush()
    let reopened = WorkspaceSnapshotStore(defaults: defaults)
    XCTAssertEqual(reopened.state.openWindowRoots, ["/a", "/b"])
  }

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

  // rootA 取 /tmp/ws：槽位只记录根内标签（FR-7.4 审查修复），夹具文件 file1/file2 必须位于工作区内
  private let rootA = URL(fileURLWithPath: "/tmp/ws")
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

  /// FR-7.4 审查修复：Finder 裸开的异根文件标签（「仅打开文件」/ 接受设工作区前的旧槽）
  /// 不得写入当前工作区槽位——否则重启/切回后恢复该文件必 EPERM（Finder 授权不跨会话）。
  /// 工作区内文件（含子目录后代）与 nil url 草稿照常记录
  @MainActor
  func testForeignRootTabsAreNotRecordedIntoSlot() throws {
    let store = WorkspaceStateStore(defaults: defaults)
    let tabStore = TabStore()
    store.workspaceDidChange(root: rootA, collapsedFolders: [])
    // 与 ContentView.onAppear 一致的接线
    tabStore.onStructureChange = { [weak tabStore] in
      guard let tabStore else { return }
      store.tabsDidChange(groups: tabStore.groups, activeGroupID: tabStore.activeGroupID)
    }

    // 工作区内文件与子目录后代：照常入槽
    tabStore.open(FileNode(id: file1, name: "a.md", kind: .markdown))
    let descendant = URL(fileURLWithPath: "/tmp/ws/notes/c.md")
    tabStore.open(FileNode(id: descendant, name: "c.md", kind: .markdown))
    // 异根文件（裸开）：不入槽
    let foreign = URL(fileURLWithPath: "/elsewhere/x.pdf")
    tabStore.open(url: foreign)
    store.flush()

    let data = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot.v1"))
    let snapshot = try JSONDecoder().decode(WorkspaceStateStore.Snapshot.self, from: data)
    let key = rootA.standardizedFileURL.path
    let ws = try XCTUnwrap(snapshot.workspaces[key])
    XCTAssertEqual(
      ws.groups.flatMap { $0 }.compactMap(\.path),
      [file1.path, descendant.path],
      "异根标签不得污染当前工作区槽位；根后代照常记录"
    )
    // 激活标签是异根文件：记为 nil（恢复时回退组内首个），不得记录异根路径
    XCTAssertEqual(ws.activeTabs.count, 1)
    XCTAssertNil(ws.activeTabs[0], "异根激活标签不得入槽（重启恢复必 EPERM）")
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
    // 打开的文件必须在工作区内（FR-7.4 审查修复：异根标签不再入槽）
    let aFile = rootA.appendingPathComponent("a.md")
    tabStore.open(FileNode(id: aFile, name: "a.md", kind: .markdown))

    // 切到 B：此间 collapsedFolders 赋值会以旧 root(A) 触发路过事件
    store.switchWorkspace(to: rootB, workspaceStore: ws, tabStore: tabStore)
    store.flush()

    let data = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot.v1"))
    let snapshot = try JSONDecoder().decode(WorkspaceStateStore.Snapshot.self, from: data)
    XCTAssertEqual(
      snapshot.workspaces[rootA.standardizedFileURL.path]?.groups.flatMap { $0 }.compactMap(\.path),
      [aFile.path],
      "旧工作区槽位必须保留真实标签，不得被切换期间的路过事件覆盖"
    )
    XCTAssertEqual(store.currentRootPath, rootB.standardizedFileURL.path)

    // 切回 A：真实标签应恢复（而非只剩空白草稿）
    store.switchWorkspace(to: rootA, workspaceStore: ws, tabStore: tabStore)
    XCTAssertTrue(
      tabStore.groups[0].tabs.contains(where: { $0.url == aFile }),
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
  /// 恢复编排期保护：restoreWorkspace 后 root 尚未异步就绪，折叠态/AI 显隐赋值的
  /// 路过事件（root=nil）不得把 currentRootPath 瞬态打回 nil（路由失真窗口）
  @MainActor
  func testRestoreKeepsRootPathDuringPassThroughEvents() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("RestoreGuard.\(UUID().uuidString)")
    let wsDir = parent.appendingPathComponent("ws")
    try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let rootPath = wsDir.resolvingSymlinksInPath().path
    let bookmark = try wsDir.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    var snapshot = WorkspaceSnapshotStore.Snapshot()
    snapshot.bookmarks[rootPath] = bookmark
    snapshot.lastRootPath = rootPath
    defaults.set(try JSONEncoder().encode(snapshot), forKey: "workspaceSnapshot.v1")

    let stateStore = WorkspaceStateStore(defaults: defaults)
    let workspaceStore = WorkspaceStore()
    stateStore.restoreWorkspace(into: workspaceStore, rootPath: rootPath)
    XCTAssertEqual(stateStore.currentRootPath, rootPath, "恢复即设当前根")

    // 模拟 collapsedFolders/isAIAssistantPresented 赋值触发的路过 onStateChange（root 仍 nil）
    stateStore.workspaceDidChange(root: nil, collapsedFolders: [])
    XCTAssertEqual(stateStore.currentRootPath, rootPath, "恢复窗口期的 nil 路过不得打回当前根")
  }

}
