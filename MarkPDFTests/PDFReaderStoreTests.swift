import XCTest

@testable import MarkPDF

/// 待跳转页 URL 仲裁（Bug 回归：pendingPage 不带目标 URL 时，分栏/已开 PDF 场景
/// 任何已挂载文档的视图都会抢消费，回链/搜索命中跳错文档）
@MainActor
final class PDFReaderStoreTests: XCTestCase {
  private let urlA = URL(fileURLWithPath: "/tmp/a.pdf")
  private let urlB = URL(fileURLWithPath: "/tmp/b.pdf")

  /// 目标 URL 匹配：取出页码，闪烁标记一并消费
  func testConsumePendingJumpMatchingURL() {
    let store = PDFReaderStore()
    store.pendingJump = (url: urlB, page: 5)
    store.pendingFlash = true

    let consumed = store.consumePendingJump(for: urlB)
    XCTAssertEqual(consumed?.page, 5)
    XCTAssertEqual(consumed?.flash, true)
    XCTAssertNil(store.pendingJump, "消费后待跳转必须清空")
    XCTAssertFalse(store.pendingFlash, "闪烁标记随跳转一并消费")
  }

  /// URL 不匹配不消费：分栏双 PDF 时非目标视图（A）不得抢跳；
  /// 待跳转原样保留，目标视图（B）之后仍可消费
  func testConsumePendingJumpOtherURLStaysPending() {
    let store = PDFReaderStore()
    store.pendingJump = (url: urlB, page: 5)
    store.pendingFlash = true

    XCTAssertNil(store.consumePendingJump(for: urlA), "非目标文档的视图不得消费")
    XCTAssertNotNil(store.pendingJump, "未匹配的待跳转必须保留")
    XCTAssertTrue(store.pendingFlash, "闪烁标记随保留的跳转一并保留")

    let consumed = store.consumePendingJump(for: urlB)
    XCTAssertEqual(consumed?.page, 5)
    XCTAssertEqual(consumed?.flash, true)
    XCTAssertNil(store.pendingJump)
  }

  /// URL 比较走标准化：路径写法不同（含 ./、../）但指向同一文件也视为匹配
  func testConsumePendingJumpNormalizesURL() {
    let messy = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("sub")
      .appendingPathComponent("..")
      .appendingPathComponent("b.pdf")
    XCTAssertNotEqual(messy, urlB, "前置：未标准化的路径写法应与目标 URL 不相等")

    let store = PDFReaderStore()
    store.pendingJump = (url: messy, page: 3)

    let consumed = store.consumePendingJump(for: urlB)
    XCTAssertEqual(consumed?.page, 3, "标准化后指向同一文件必须匹配")
    XCTAssertNil(store.pendingJump)
  }

  /// 无待跳转时消费返回 nil
  func testConsumeWithoutPendingJumpReturnsNil() {
    XCTAssertNil(PDFReaderStore().consumePendingJump(for: urlA))
  }

  /// URL 比较含符号链接归一（与标注写回 isSameFile 同口径）：
  /// /var 与 /private/var 形态指向同一文件必须匹配，否则符号链接路径下回链跳转卡死
  func testConsumePendingJumpResolvesSymlinks() throws {
    let realDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("JumpSymlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: realDir) }
    let file = realDir.appendingPathComponent("paper.pdf")
    try Data().write(to: file)
    // 沙盒容器的临时目录未必经符号链接：自建符号链接保证两种形态真实存在
    let linkDir = realDir.deletingLastPathComponent().appendingPathComponent("linkdir")
    try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
    let fileViaLink = linkDir.appendingPathComponent("paper.pdf")
    XCTAssertNotEqual(fileViaLink.standardizedFileURL.path, fileViaLink.resolvingSymlinksInPath().path)

    let store = PDFReaderStore()
    store.pendingJump = (url: fileViaLink, page: 7)
    let consumed = store.consumePendingJump(for: file.resolvingSymlinksInPath())
    XCTAssertEqual(consumed?.page, 7, "符号链接形态与真实路径形态指向同一文件必须匹配")
  }

  // MARK: - 文档切换状态复位（Bug 修复 1/2）

  /// 切文档必须整体复位查找状态：findMatches 持有旧文档 PDFSelection，不清理则
  /// ⌘G/回车会把旧 selection setCurrentSelection 到新文档（行为未定义），查找栏还显示旧命中数
  func testResetForDocumentSwitchClearsFindState() {
    let store = PDFReaderStore()
    store.presentFindBar()
    store.findQuery = "关键词"
    XCTAssertTrue(store.isFindBarVisible)

    store.resetForDocumentSwitch()

    XCTAssertFalse(store.isFindBarVisible, "切文档后查找栏必须关闭")
    XCTAssertEqual(store.findQuery, "", "搜索词必须清空")
    XCTAssertTrue(store.findMatches.isEmpty, "旧文档命中必须清空（PDFSelection 绑定旧文档）")
    XCTAssertEqual(store.currentMatchIndex, 0)
    XCTAssertEqual(store.matchCountText, "", "不得残留旧文档命中数显示")
  }

  /// 切文档必须重置缩放：否则旧倍率（如 2.0）在新文档加载窗口期（scaleFactor 仍是初值 1.0）
  /// 经 updateNSView 同步误关 autoScales，新文档失去自适应宽度
  func testResetForDocumentSwitchResetsScale() {
    let store = PDFReaderStore()
    store.scale = 2.0
    store.resetForDocumentSwitch()
    XCTAssertEqual(store.scale, 1.0, "切文档后缩放必须归位（存档缩放由加载完成后的位置恢复重设）")
  }

  /// 切文档必须归零页码：新文档异步解析的窗口期内若停留旧文档页码，
  /// 「书签当前页」会把旧页码写进新文件的书签表（错档书签）
  func testResetForDocumentSwitchClearsPage() {
    let store = PDFReaderStore()
    store.currentPage = 37
    store.pageCount = 112
    store.resetForDocumentSwitch()
    XCTAssertEqual(store.currentPage, 0, "旧文档页码不得带入新文档加载窗口期")
    XCTAssertEqual(store.pageCount, 0)
  }

  // MARK: - 解析失败上报（Bug 修复 3）

  /// 解析失败必须用户可感知（NFR-5）：经 lastError 暴露，含文件名
  func testReportLoadFailureExposesError() {
    let store = PDFReaderStore()
    XCTAssertNil(store.lastError)
    store.reportLoadFailure(for: URL(fileURLWithPath: "/tmp/坏文件.pdf"))
    XCTAssertNotNil(store.lastError, "解析失败必须经 lastError 暴露")
    XCTAssertTrue(store.lastError!.contains("坏文件.pdf"), "错误信息须含文件名")
  }
}
