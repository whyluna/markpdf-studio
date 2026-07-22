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

  // MARK: - 防抖窗口内 flush 写回（Bug C1 回归）

  /// 建临时目录 + 落盘一页 PDF，返回 (目录, 文件 URL, 文档)
  private func makePDFFixture() throws -> (URL, URL, PDFDocument) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFAnnotationStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("a.pdf")
    let doc = makePDFDocument()
    XCTAssertTrue(doc.write(to: url))
    return (dir, url, doc)
  }

  private func makeHighlight() -> PDFAnnotation {
    PDFAnnotation(
      bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
      forType: .highlight, withProperties: nil)
  }

  /// 切档/关窗路径依赖：标注变更后未过 500ms 防抖期即 flushPendingWrites，
  /// 写回必须立即执行（此前仅靠防抖触发，视图清空 document 后弱引用失效会静默丢失）
  func testFlushPendingWritesWithinDebounceWindow() throws {
    let (dir, url, doc) = try makePDFFixture()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = makeStore()
    store.attach(document: doc, url: url)
    store.add(makeHighlight(), to: doc.page(at: 0)!)
    XCTAssertTrue(store.hasUnsavedChanges, "变更后应处于待写回状态（防抖窗口内）")

    store.flushPendingWrites()
    XCTAssertFalse(store.hasUnsavedChanges, "flush 后不应有未写回改动")
    XCTAssertNil(store.lastError)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
      "flush 必须立即执行写回（.bak 在首次写回前创建）")
  }

  /// 切换只读模式前先落盘挂起改动（Bug C1 同类）：否则变更会被写进新目的地
  func testSetSidecarModeFlushesPendingWritesBeforeSwitch() throws {
    let (dir, url, doc) = try makePDFFixture()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = makeStore()
    store.attach(document: doc, url: url)
    store.add(makeHighlight(), to: doc.page(at: 0)!)

    store.setSidecarMode(true)
    XCTAssertTrue(store.isSidecarMode)
    XCTAssertFalse(store.hasUnsavedChanges, "切换写回通道前必须落盘挂起改动")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
      "挂起改动应在切换前写回 PDF 本体")
  }
}
