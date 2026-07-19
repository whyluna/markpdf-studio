import XCTest
@testable import MarkPDF

/// 设置持久化（FR-7.2）：默认值、读写回环、跨实例保留
final class SettingsStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "SettingsStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  @MainActor
  func testDefaults() {
    let store = SettingsStore(defaults: defaults)
    XCTAssertEqual(store.editorFont, .system)
    XCTAssertEqual(store.editorFontSize, SettingsStore.defaultFontSize)
    XCTAssertEqual(store.editorLineHeight, SettingsStore.defaultLineHeight)
    XCTAssertEqual(store.pdfViewMode, .continuous)
  }

  @MainActor
  func testPersistAcrossInstances() {
    let store = SettingsStore(defaults: defaults)
    store.editorFont = .serif
    store.editorFontSize = 17
    store.editorLineHeight = 2.0
    store.pdfViewMode = .twoPages

    let reopened = SettingsStore(defaults: defaults)
    XCTAssertEqual(reopened.editorFont, .serif)
    XCTAssertEqual(reopened.editorFontSize, 17)
    XCTAssertEqual(reopened.editorLineHeight, 2.0)
    XCTAssertEqual(reopened.pdfViewMode, .twoPages)
  }

  @MainActor
  func testCorruptValuesFallBackToDefault() {
    defaults.set("nonsense", forKey: "settings.editorFont")
    defaults.set(-5.0, forKey: "settings.editorFontSize")
    defaults.set("nonsense", forKey: "settings.pdfViewMode")
    let store = SettingsStore(defaults: defaults)
    XCTAssertEqual(store.editorFont, .system)
    XCTAssertEqual(store.editorFontSize, SettingsStore.defaultFontSize)
    XCTAssertEqual(store.pdfViewMode, .continuous)
  }

  func testPDFViewModeMapping() {
    XCTAssertEqual(SettingsStore.PDFViewMode.continuous.pdfDisplayMode, .singlePageContinuous)
    XCTAssertEqual(SettingsStore.PDFViewMode.singlePage.pdfDisplayMode, .singlePage)
    XCTAssertEqual(SettingsStore.PDFViewMode.twoPages.pdfDisplayMode, .twoUpContinuous)
  }
}
