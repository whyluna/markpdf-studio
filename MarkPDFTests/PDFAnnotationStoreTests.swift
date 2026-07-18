import XCTest
@testable import MarkPDF

/// FR-4.4 颜色系统单测：各类型默认色、最近用色按类型独立记忆、UserDefaults 持久化
@MainActor
final class PDFAnnotationStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    suiteName = "PDFAnnotationStoreTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suiteName)
  }

  private func makeStore() -> PDFAnnotationStore {
    PDFAnnotationStore(writer: LiveAnnotationWriter(), defaults: defaults)
  }

  func testDefaultColorsWhenNothingPersisted() {
    let store = makeStore()
    XCTAssertEqual(store.colorsByKind[.highlight], .yellow)
    XCTAssertEqual(store.colorsByKind[.underline], .blue)
    XCTAssertEqual(store.colorsByKind[.strikeOut], .red)
    XCTAssertEqual(store.paletteKind, .highlight)
  }

  func testRememberIsPerKind() {
    let store = makeStore()
    store.remember(color: .red, for: .highlight)
    XCTAssertEqual(store.colorsByKind[.highlight], .red)
    // 其他类型保持自己的默认色
    XCTAssertEqual(store.colorsByKind[.underline], .blue)
    XCTAssertEqual(store.colorsByKind[.strikeOut], .red)
  }

  func testRememberedColorPersistsAcrossInstances() {
    makeStore().remember(color: .green, for: .underline)
    let reloaded = makeStore()
    XCTAssertEqual(reloaded.colorsByKind[.underline], .green)
    // 未改动的类型仍是默认色
    XCTAssertEqual(reloaded.colorsByKind[.highlight], .yellow)
  }

  func testCorruptPersistedValueFallsBackToDefault() {
    defaults.set("not-a-color", forKey: "annotationColor.highlight")
    XCTAssertEqual(makeStore().colorsByKind[.highlight], .yellow)
  }
}
