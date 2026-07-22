import PDFKit
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

  // MARK: - 写回失败上报（NFR-5）

  /// 构造一页空白 PDF（NSImage 需含真实位图内容，否则 PDFPage 拒绝）
  private func makePDFDocument() -> PDFDocument {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 100,
      pixelsHigh: 100,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )!
    let image = NSImage(size: NSSize(width: 100, height: 100))
    image.addRepresentation(rep)
    let doc = PDFDocument()
    doc.insert(PDFPage(image: image)!, at: 0)
    return doc
  }

  /// 写回失败必须经 lastError 上报；持续失败只提示一次，写回恢复后复位
  func testWriteBackFailureReportsOnceAndRecovers() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFAnnotationStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("a.pdf")
    let doc = makePDFDocument()
    XCTAssertTrue(doc.write(to: url))

    let store = makeStore()
    store.attach(document: doc, url: url)
    XCTAssertNil(store.lastError)

    // 原文件消失 → 首次写回创建 .bak 失败 → 上报
    try FileManager.default.removeItem(at: url)
    store.markDirty()
    store.flushPendingWrites()
    XCTAssertNotNil(store.lastError, "写回失败必须上报")

    // 持续失败不重复上报（每次标注变更都会重试，防弹窗轰炸）
    store.lastError = nil
    store.markDirty()
    store.flushPendingWrites()
    XCTAssertNil(store.lastError, "持续失败只提示一次")

    // 写回恢复成功后复位；再次失败会再次上报
    XCTAssertTrue(doc.write(to: url))
    store.markDirty()
    store.flushPendingWrites()
    XCTAssertFalse(store.hasUnsavedChanges, "恢复后应写回成功")
    try FileManager.default.removeItem(at: url)
    try FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
    store.markDirty()
    store.flushPendingWrites()
    XCTAssertNotNil(store.lastError, "恢复后再失败应再次上报")
  }
}
