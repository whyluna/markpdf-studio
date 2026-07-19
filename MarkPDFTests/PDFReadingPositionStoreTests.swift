import XCTest
@testable import MarkPDF

/// 阅读位置记忆（FR-3.5）：读写回环、未知文件、损坏数据回退、覆盖更新
final class PDFReadingPositionStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: PDFReadingPositionStore!

  @MainActor
  override func setUp() {
    super.setUp()
    suiteName = "PDFReadingPositionStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = PDFReadingPositionStore(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private let url = URL(fileURLWithPath: "/tmp/论文.pdf")

  @MainActor
  func testRoundTrip() {
    store.save(.init(page: 7, scale: 1.75), for: url)
    let restored = store.position(for: url)
    XCTAssertEqual(restored, .init(page: 7, scale: 1.75))
  }

  @MainActor
  func testUnknownFileReturnsNil() {
    XCTAssertNil(store.position(for: url))
  }

  @MainActor
  func testCorruptValueReturnsNil() {
    defaults.set(["not-a-dict"], forKey: "pdfReadingPositions")
    XCTAssertNil(store.position(for: url))
  }

  @MainActor
  func testCorruptEntryReturnsNil() {
    defaults.set([url.path: ["page": "三", "scale": "big"]], forKey: "pdfReadingPositions")
    XCTAssertNil(store.position(for: url))
  }

  @MainActor
  func testOverwriteUpdates() {
    store.save(.init(page: 1, scale: 1.0), for: url)
    store.save(.init(page: 12, scale: 2.0), for: url)
    XCTAssertEqual(store.position(for: url), .init(page: 12, scale: 2.0))
  }

  @MainActor
  func testPersistsAcrossInstances() {
    store.save(.init(page: 5, scale: 1.25), for: url)
    let reopened = PDFReadingPositionStore(defaults: defaults)
    XCTAssertEqual(reopened.position(for: url), .init(page: 5, scale: 1.25))
  }
}
