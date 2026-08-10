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

/// 空转当前 RunLoop，让排队的回主线程回调落地
private func pump(_ seconds: TimeInterval) {
  RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

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
    XCTAssertTrue(waitUntil { store.lastError != nil }, "读取失败必须上报")
    XCTAssertNil(store.currentFileURL, "失败后不应指向该文件")
  }

  func testAutosaveFailureReportsOnceAndRecovers() throws {
    let url = dir.appendingPathComponent("a.md")
    try "初始".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    XCTAssertTrue(waitUntil { store.currentFileURL == url }, "后台读盘应完成")
    XCTAssertNil(store.lastError)

    // 目录消失 → 原子写盘必失败 → 首次失败上报
    try FileManager.default.removeItem(at: dir)
    store.contentDidChange("改动 1")
    store.flushPendingSave()
    XCTAssertTrue(waitUntil { store.lastError != nil }, "保存失败必须上报")

    // 持续失败不重复上报（内容每变一次都会重试，防击键级弹窗轰炸）
    store.lastError = nil
    store.contentDidChange("改动 2")
    store.flushPendingSave()
    pump(0.3) // 等失败回调落地
    XCTAssertNil(store.lastError, "持续失败只提示一次")

    // 写盘恢复成功后复位；再次失败会再次上报
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    store.contentDidChange("改动 3")
    store.flushPendingSave()
    XCTAssertTrue(waitUntil { !store.hasUnsavedChanges }, "恢复后应写盘成功")
    try FileManager.default.removeItem(at: dir)
    store.contentDidChange("改动 4")
    store.flushPendingSave()
    XCTAssertTrue(waitUntil { store.lastError != nil }, "恢复后再失败应再次上报")
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

/// B4 回归：分栏时同一文件只允许打开一个实例——对已在另一组打开的文件再 open，
/// 应激活该组已有标签，不得在当前组重复开标签
/// （两套 EditorStore 各自自动保存同一磁盘文件，后写覆盖先写，编辑互相吞）
@MainActor
final class TabStoreCrossGroupOpenTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TabStoreCrossGroupOpenTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func makeMarkdown(_ name: String, _ text: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// 左组开 a.md → 分栏激活右组开 b.md → 再 open a.md：标签总数不变，切回左组激活已有标签
  func testOpenExistingFileActivatesItsGroupInsteadOfDuplicating() throws {
    let aURL = try makeMarkdown("a.md", "# a")
    let bURL = try makeMarkdown("b.md", "# b")
    let store = TabStore()

    store.open(FileNode(id: aURL, name: "a.md", kind: .markdown))
    let leftID = store.activeGroupID

    store.toggleSplit()
    XCTAssertEqual(store.groups.count, 2)
    let rightID = store.groups[1].id
    store.activeGroupID = rightID
    store.open(FileNode(id: bURL, name: "b.md", kind: .markdown))
    XCTAssertEqual(store.groups[1].tabs.map(\.url), [bURL])

    let totalBefore = store.groups.reduce(0) { $0 + $1.tabs.count }
    store.open(FileNode(id: aURL, name: "a.md", kind: .markdown))

    XCTAssertEqual(store.groups.reduce(0) { $0 + $1.tabs.count }, totalBefore, "同一文件不得重复开标签")
    XCTAssertEqual(store.groups[1].tabs.map(\.url), [bURL], "右组不应新增 a.md 标签")
    XCTAssertEqual(store.activeGroupID, leftID, "应切回已有标签所在组")
    XCTAssertEqual(store.activeGroup.activeTab?.url, aURL, "应激活已有的 a.md 标签")
  }

  /// open(url:) 重载同样跨组去重（导出笔记后打开、最近打开等入口）
  func testOpenByURLDeduplicatesAcrossGroups() throws {
    let aURL = try makeMarkdown("a.md", "# a")
    let store = TabStore()

    store.open(url: aURL)
    let leftID = store.activeGroupID
    store.toggleSplit()
    store.activeGroupID = store.groups[1].id

    let totalBefore = store.groups.reduce(0) { $0 + $1.tabs.count }
    store.open(url: aURL)

    XCTAssertEqual(store.groups.reduce(0) { $0 + $1.tabs.count }, totalBefore, "url 重载同样不得重复开标签")
    XCTAssertEqual(store.activeGroupID, leftID)
    XCTAssertEqual(store.activeGroup.activeTab?.url, aURL)
  }

  /// url=nil 的草稿标签不参与匹配：另一组有草稿时 open 文件仍新建文件标签
  ///（未触碰的欢迎草稿随开随关，见 closeUntouchedWelcomeDrafts）
  func testDraftTabsNeverMatchFileURL() throws {
    let aURL = try makeMarkdown("a.md", "# a")
    let store = TabStore()
    store.toggleSplit()
    let rightID = store.groups[1].id
    store.activeGroupID = rightID
    store.groups[1].openDraft()

    store.open(FileNode(id: aURL, name: "a.md", kind: .markdown))

    XCTAssertEqual(store.activeGroupID, rightID, "无匹配文件标签时仍在当前组打开")
    XCTAssertEqual(store.activeGroup.activeTab?.url, aURL, "草稿不得被当成 a.md 复用")
    XCTAssertEqual(store.activeGroup.tabs.count, 1, "未触碰的欢迎草稿随开随关")
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
    XCTAssertTrue(waitUntil { store.currentFileURL == url }, "后台读盘应完成")
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
    XCTAssertTrue(waitUntil { store.currentFileURL == url && store.text == "磁盘 v1" }, "后台读盘应完成")

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
    XCTAssertTrue(waitUntil { store.currentFileURL == url && store.text == "磁盘 v2" }, "放回后应重载磁盘内容")

    // 恢复后自动保存可正常落盘
    store.contentDidChange("磁盘 v2 追加")
    store.flushPendingSave()
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "磁盘 v2 追加")
  }
}

/// 批次三·性能：文本统计防抖（FR-2.8 口径不变，只延迟刷新时机；最终值收敛到最新文本）。
/// 修复前 text didSet 逐键同步 TextStatistics.of（O(n) 全量扫描，长文档主线程毛刺源）
@MainActor
final class StatsDebounceTests: XCTestCase {
  /// 防抖窗口内：text 变更不触发同步统计（击键路径无 O(n) 全量扫描）
  func testStatsDoNotRecomputeSynchronouslyOnChange() {
    let store = EditorStore()
    let before = store.stats
    store.text = "全新的文档内容"
    XCTAssertEqual(store.stats, before, "防抖窗口内统计不得逐键刷新")
  }

  /// 停止输入后：连续变更合并为一次，最终值与 TextStatistics.of(最新文本) 一致
  func testStatsConvergeToLatestTextAfterDebounce() {
    let store = EditorStore()
    let done = expectation(description: "防抖后统计收敛")
    store.text = "知识管理"
    store.text = "知识管理 note"
    store.text = "hello world"
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
      XCTAssertEqual(store.stats, TextStatistics.of("hello world"), "最终值须收敛到最新文本的口径")
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
  }
}

/// 批次三·性能：EditorStore 异步读写——后台读盘 + 主线程应用（代际号防串档）、
/// 快照 + 串行后台队列写盘（hasUnsavedChanges / lastPersistedText 在主线程完成回调收口）
@MainActor
final class EditorStoreAsyncIOTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EditorStoreAsyncIOTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  /// 后台读盘：成功后状态收敛（URL/文本/未保存标记），且内核回显不算改动
  func testLoadFileAppliesContentAfterBackgroundRead() throws {
    let url = dir.appendingPathComponent("a.md")
    try "磁盘内容".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    XCTAssertTrue(waitUntil { store.currentFileURL == url }, "后台读盘应完成")
    XCTAssertEqual(store.text, "磁盘内容")
    XCTAssertFalse(store.hasUnsavedChanges)
    // setContent 回显（与磁盘一致）不算改动
    store.contentDidChange("磁盘内容")
    XCTAssertFalse(store.hasUnsavedChanges)
  }

  /// 代际号：加载途中再 loadFile 另一文件，先到的旧结果不得覆盖新状态
  func testStaleLoadResultDoesNotOverrideNewerLoad() throws {
    let urlA = dir.appendingPathComponent("a.md")
    let urlB = dir.appendingPathComponent("b.md")
    try "内容 A".write(to: urlA, atomically: true, encoding: .utf8)
    try "内容 B".write(to: urlB, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(urlA)
    store.loadFile(urlB)
    XCTAssertTrue(waitUntil { store.currentFileURL == urlB })
    pump(0.3) // 留出让 A 的过期结果（若未被代际号拦截）落地的窗口
    XCTAssertEqual(store.currentFileURL, urlB, "旧加载结果不得覆盖新文件")
    XCTAssertEqual(store.text, "内容 B")
    XCTAssertFalse(store.hasUnsavedChanges)
  }

  /// 快照写盘：flush 屏障返回时改动确已落盘；写盘完成回调后橙点熄灭
  func testFlushPersistsSnapshotAndClearsDirty() throws {
    let url = dir.appendingPathComponent("c.md")
    try "v1".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    XCTAssertTrue(waitUntil { store.currentFileURL == url })

    store.contentDidChange("v2")
    XCTAssertTrue(store.hasUnsavedChanges)
    store.flushPendingSave()
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "v2", "flush 返回时改动须已落盘")
    XCTAssertTrue(waitUntil { !store.hasUnsavedChanges }, "写盘完成回调后橙点熄灭")
  }

  /// 自动保存防抖链路：不手动 flush 也按时落盘（0.5s 防抖 + 后台写）
  func testAutosaveWritesAfterDebounceWithoutFlush() throws {
    let url = dir.appendingPathComponent("d.md")
    try "v1".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    XCTAssertTrue(waitUntil { store.currentFileURL == url })

    store.contentDidChange("自动落盘")
    XCTAssertTrue(
      waitUntil { (try? String(contentsOf: url, encoding: .utf8)) == "自动落盘" },
      "防抖后应自动写回磁盘"
    )
    XCTAssertTrue(waitUntil { !store.hasUnsavedChanges })
  }

  /// fileDidMove：磁盘被修正（FR-2.5 链接重写）时以磁盘为准重载（后台重读）
  func testFileDidMoveReloadsFromDiskWhenChanged() throws {
    let oldURL = dir.appendingPathComponent("old.md")
    let newURL = dir.appendingPathComponent("new.md")
    try "原文".write(to: oldURL, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(oldURL)
    XCTAssertTrue(waitUntil { store.currentFileURL == oldURL })

    // 模拟移动 + 磁盘修正
    try "修正后".write(to: newURL, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: oldURL)
    store.fileDidMove(from: oldURL, to: newURL)
    XCTAssertEqual(store.currentFileURL, newURL, "标识应立即跟随新路径")
    XCTAssertTrue(waitUntil { store.text == "修正后" }, "磁盘与上次落盘不一致应以磁盘为准")
    XCTAssertFalse(store.hasUnsavedChanges)
  }

  /// fileDidMove：纯重命名（磁盘内容不变）不影响未落盘编辑
  func testFileDidMoveKeepsUnsavedEditsWhenDiskUnchanged() throws {
    let oldURL = dir.appendingPathComponent("old2.md")
    let newURL = dir.appendingPathComponent("new2.md")
    try "原文".write(to: oldURL, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(oldURL)
    XCTAssertTrue(waitUntil { store.currentFileURL == oldURL })

    store.contentDidChange("未落盘")
    try FileManager.default.moveItem(at: oldURL, to: newURL)
    store.fileDidMove(from: oldURL, to: newURL)
    pump(0.3) // 等后台重读落地（磁盘一致 → 不得覆盖未落盘编辑）
    XCTAssertEqual(store.text, "未落盘", "磁盘无变化不得覆盖未落盘编辑")
    XCTAssertTrue(store.hasUnsavedChanges)
  }

  /// 在途加载期间文件被移入废纸篓：加载结果不得把已删文件重新认作当前文件
  func testTrashDuringInflightLoadDiscardsResult() throws {
    let url = dir.appendingPathComponent("e.md")
    try "内容".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    store.fileWasTrashed(url) // 加载未完成即进废纸篓
    pump(0.3) // 等加载结果落地窗口
    XCTAssertNil(store.currentFileURL, "在途加载结果不得复活已入废纸篓的文件")
    XCTAssertEqual(store.trashedFileURL, url)
    XCTAssertFalse(store.hasUnsavedChanges)
  }

  /// 内核命令队列（FR-AI.2）：enqueue 入队发布、消费后清空
  func testKernelRequestQueue() {
    let store = EditorStore()
    XCTAssertTrue(store.pendingKernelRequests.isEmpty)

    store.enqueue(.insertAtCursor("文本"))
    store.fetchSelection { _ in }
    XCTAssertEqual(store.pendingKernelRequests.count, 2)

    store.didHandleKernelRequests()
    XCTAssertTrue(store.pendingKernelRequests.isEmpty)
  }
}
