import XCTest
@testable import MarkPDF

/// 工作区状态持久化（FR-1.6）：快照记录/恢复、兼容解码、损坏回退
final class WorkspaceStateStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "WorkspaceStateStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
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
    store.tabsDidChange(groups: source.groups, activeGroupID: source.activeGroupID)
    store.flush()

    // 新实例 + 新 TabStore（模拟重启）恢复
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
    store.workspaceDidChange(root: nil, collapsedFolders: [URL(fileURLWithPath: "/tmp/ws/sub")])
    store.flush()
    let data = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot.v1"))
    let snapshot = try JSONDecoder().decode(WorkspaceStateStore.Snapshot.self, from: data)
    XCTAssertEqual(snapshot.collapsedFolders, ["/tmp/ws/sub"])
    XCTAssertNil(snapshot.rootBookmark)
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
}
