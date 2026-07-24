import XCTest
@testable import MarkPDF

/// 设置持久化（FR-7.2）：默认值、读写回环、跨实例保留
final class SettingsStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    // 固定 suite 名 + 用前清场：避免 UUID 随机名在磁盘堆积 plist
    suiteName = "SettingsStoreTests"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
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

  // MARK: - 界面语言（重启后生效）

  @MainActor
  func testAppLanguageDefaultAndPersistence() {
    let store = SettingsStore(defaults: defaults)
    XCTAssertEqual(store.appLanguage, .system)

    store.appLanguage = .en
    let reopened = SettingsStore(defaults: defaults)
    XCTAssertEqual(reopened.appLanguage, .en)
  }

  @MainActor
  func testAppLanguageCorruptFallsBackToSystem() {
    defaults.set("klingon", forKey: "settings.appLanguage")
    XCTAssertEqual(SettingsStore(defaults: defaults).appLanguage, .system)
  }

  func testAppleLanguagesValueMapping() {
    XCTAssertNil(SettingsStore.appleLanguagesValue(for: .system))
    XCTAssertEqual(SettingsStore.appleLanguagesValue(for: .zhHans), ["zh-Hans"])
    XCTAssertEqual(SettingsStore.appleLanguagesValue(for: .en), ["en"])
  }

  @MainActor
  func testAppLanguageWritesAndRemovesAppleLanguagesOverride() {
    let store = SettingsStore(defaults: defaults)
    store.appLanguage = .en
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

    store.appLanguage = .zhHans
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])

    // 跟随系统 = 移除覆盖（object(forKey:) 会回落 NSGlobalDomain，须查本 suite 域）
    store.appLanguage = .system
    XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
  }

  @MainActor
  func testEffectiveWebLocale() {
    let store = SettingsStore(defaults: defaults)
    store.appLanguage = .zhHans
    XCTAssertEqual(store.effectiveWebLocale, "zh")
    store.appLanguage = .en
    XCTAssertEqual(store.effectiveWebLocale, "en")
    store.appLanguage = .system
    XCTAssertTrue(["zh", "en"].contains(store.effectiveWebLocale))
  }
}
