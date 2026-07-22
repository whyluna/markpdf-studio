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
}
