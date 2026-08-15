import XCTest

@testable import MarkPDF

/// 轮询等待异步收口（后台读写 / 防抖结果回主线程）
private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
  }
  return condition()
}

/// 批次四·标签组：store 动作阶段预建（修 body 求值期发布）、文件夹移动/删除的后代前缀迁移、
/// 重命名换扩展名后 kind 重算
@MainActor
final class TabGroupTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TabGroupTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func makeFile(_ name: String, in folder: URL? = nil, text: String = "内容") throws -> URL {
    let url = (folder ?? dir).appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  // MARK: - store 动作阶段预建（body 只读已建好的）

  /// open 动作阶段预建 EditorStore 并开始载入：body 首次求值即命中缓存，
  /// 不再于视图更新途中建 store / loadFile
  func testOpenPrecreatesEditorStore() throws {
    let url = try makeFile("a.md")
    let group = TabGroup()
    group.open(FileNode(id: url, name: "a.md", kind: .markdown))
    let tab = try XCTUnwrap(group.tabs.first)
    let store = try XCTUnwrap(group.editorStores[tab.id], "open 应同步建好编辑状态")
    XCTAssertTrue(waitUntil { store.currentFileURL == url }, "预建时应已开始载入磁盘内容")
  }

  /// 非 md 标签不建 EditorStore（与此前惰性创建的口径一致）
  func testOpenNonMarkdownDoesNotPrecreateStore() throws {
    let url = try makeFile("p.pdf")
    let group = TabGroup()
    group.open(FileNode(id: url, name: "p.pdf", kind: .pdf))
    XCTAssertTrue(group.editorStores.isEmpty)
  }

  /// restore（启动恢复现场）动作阶段预建：恢复的文件标签即刻拥有编辑状态
  func testRestorePrecreatesStores() throws {
    let url = try makeFile("r.md")
    let tabStore = TabStore()
    tabStore.restore(
      tabStates: [[WorkspaceStateStore.TabState(path: url.path, kind: "markdown")]],
      activeTabPaths: [url.path],
      activeGroupIndex: 0
    )
    let group = tabStore.groups[0]
    let tab = try XCTUnwrap(group.tabs.first)
    XCTAssertNotNil(group.editorStores[tab.id], "restore 应同步建好编辑状态")
  }

  /// body 期缺失兜底：调用瞬间不得注册（避免视图更新途中发布），
  /// 下一 runloop 注册同一实例并载入磁盘内容
  func testFallbackDefersStoreRegistration() throws {
    let url = try makeFile("a.md")
    let group = TabGroup()
    let tab = EditorTab(url: url, kind: .markdown)
    group.tabs.append(tab) // 绕过 open，模拟漏接入预建的入口
    let store = group.editorStore(for: tab)
    XCTAssertNil(group.editorStores[tab.id], "兜底不得在调用瞬间注册（body 期发布警告源）")
    XCTAssertTrue(waitUntil { group.editorStores[tab.id] === store }, "下一 runloop 应注册同一实例")
    XCTAssertTrue(waitUntil { store.currentFileURL == url }, "注册后应载入磁盘内容")
  }

  // MARK: - 文件夹移动 / 删除的后代前缀迁移

  /// 移动含打开文件的文件夹：后代标签 URL / 编辑状态字典键 / 激活 id 按新前缀迁移
  func testFolderMoveMigratesDescendantTabs() throws {
    let folder = dir.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = try makeFile("n.md", in: folder, text: "正文")

    let group = TabGroup()
    group.open(FileNode(id: file, name: "n.md", kind: .markdown))
    let store = try XCTUnwrap(group.editorStores.values.first)
    XCTAssertTrue(waitUntil { store.currentFileURL == file }, "后台读盘应完成")

    // 磁盘移动在前、onFileMoved 回调在后（与 WorkspaceStore.move 的真实顺序一致）
    let movedFolder = dir.appendingPathComponent("sub2")
    try FileManager.default.moveItem(at: folder, to: movedFolder)
    group.fileDidMove(from: folder, to: movedFolder)

    let newURL = movedFolder.appendingPathComponent("n.md")
    XCTAssertEqual(group.tabs.first?.url, newURL, "后代标签 URL 应随文件夹迁移")
    XCTAssertEqual(group.activeTabID, newURL.path, "激活标签 id 应随路径迁移")
    XCTAssertNotNil(group.editorStores[newURL.path], "编辑状态字典键应迁移")
    XCTAssertTrue(waitUntil { store.currentFileURL == newURL }, "EditorStore 应跟随新路径")
  }

  /// 前缀匹配按路径组件边界：/a/b 移动不得误伤 /a/b2/x.md
  func testFolderMoveDoesNotMatchSiblingPrefix() throws {
    let folderB2 = dir.appendingPathComponent("b2")
    try FileManager.default.createDirectory(at: folderB2, withIntermediateDirectories: true)
    let sibling = try makeFile("x.md", in: folderB2)
    let group = TabGroup()
    group.open(FileNode(id: sibling, name: "x.md", kind: .markdown))

    group.fileDidMove(from: dir.appendingPathComponent("b"), to: dir.appendingPathComponent("b-moved"))
    XCTAssertEqual(group.tabs.first?.url, sibling, "仅字符串前缀相同不算后代，不得迁移")
  }

  /// 文件夹入废纸篓：后代标签的编辑状态转草稿（与单文件入废纸篓口径一致）
  func testFolderTrashConvertsDescendantStoresToDraft() throws {
    let folder = dir.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = try makeFile("n.md", in: folder)
    let group = TabGroup()
    group.open(FileNode(id: file, name: "n.md", kind: .markdown))
    let store = try XCTUnwrap(group.editorStores.values.first)
    XCTAssertTrue(waitUntil { store.currentFileURL == file }, "后台读盘应完成")

    group.fileWasTrashed(folder)
    XCTAssertNil(store.currentFileURL, "文件夹后代文件入废纸篓后应转草稿")
  }

  // MARK: - 重命名换扩展名 kind 重算

  /// md 改名 png：kind 按新 URL 重算，不再按 Markdown 渲染
  func testExtensionChangeRecalculatesKind() throws {
    let url = try makeFile("a.md")
    let group = TabGroup()
    group.open(FileNode(id: url, name: "a.md", kind: .markdown))
    group.fileDidMove(from: url, to: dir.appendingPathComponent("a.png"))
    XCTAssertEqual(group.tabs.first?.kind, .image)
  }

  /// png 改名 md：kind 变 markdown，且动作阶段补建编辑状态（不经 body 兜底）
  func testRenameToMarkdownCreatesStore() throws {
    let url = try makeFile("a.png", text: "文本")
    let group = TabGroup()
    group.open(FileNode(id: url, name: "a.png", kind: .image))
    XCTAssertTrue(group.editorStores.isEmpty)

    group.fileDidMove(from: url, to: dir.appendingPathComponent("a.md"))
    let tab = try XCTUnwrap(group.tabs.first)
    XCTAssertEqual(tab.kind, .markdown)
    XCTAssertNotNil(group.editorStores[tab.id], "重命名为 md 后应补建编辑状态")
  }
  /// 组内拖放到自身：不得被移到末尾
  func testMoveTabOntoItselfIsNoOp() throws {
    let group = TabGroup()
    let a = try makeFile("a.md", text: "a")
    let b = try makeFile("b.md", text: "b")
    group.open(FileNode(id: a, name: "a.md", kind: .markdown))
    group.open(FileNode(id: b, name: "b.md", kind: .markdown))
    let tabA = try XCTUnwrap(group.tabs.first { $0.url == a })

    group.moveTab(tabA, before: tabA)

    XCTAssertEqual(group.tabs.map(\.url), [a, b], "拖放到自身不得改变顺序")
  }

  /// 跨组搬运的 store 重接光标上报：源组释放后 FR-1.6 位置记忆不断线
  func testAttachRewiresCursorLineCallback() throws {
    let source = TabGroup()
    let url = try makeFile("c.md", text: "c")
    source.open(FileNode(id: url, name: "c.md", kind: .markdown))
    let tab = try XCTUnwrap(source.tabs.first)
    let store = source.editorStore(for: tab)

    let target = TabGroup()
    var reported: (URL, Int)?
    target.onEditorCursorLine = { reported = ($0, $1) }
    let detached = source.detach(tab)
    target.attach(tab, store: detached)

    XCTAssertTrue(waitUntil { store.currentFileURL == url }, "后台载入完成（cursorDidMove 需当前文件）")
    store.cursorDidMove(to: 42)
    XCTAssertEqual(reported?.1, 42, "搬运后光标上报应走新组的接线")
  }

}
