import PDFKit
import XCTest
@testable import MarkPDF

/// 只读模式 sidecar（FR-4.7）：序列化 round-trip、PDF 本体不动、模式持久化
final class SidecarAnnotationTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SidecarAnnotationTests.\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  /// 造一个含标注的单页 PDF
  private func makePDFFile() throws -> (url: URL, document: PDFDocument) {
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    let url = tempDir.appendingPathComponent("论文.pdf")
    try XCTUnwrap(document.dataRepresentation()).write(to: url)
    return (url, document)
  }

  @MainActor
  func testSidecarURLRule() {
    let pdf = URL(fileURLWithPath: "/tmp/论文.pdf")
    XCTAssertEqual(SidecarAnnotationStorage.sidecarURL(for: pdf).lastPathComponent, "论文.json")
  }

  @MainActor
  func testRoundTripPreservesAnnotations() throws {
    let (url, document) = try makePDFFile()
    let page = try XCTUnwrap(document.page(at: 0))
    let groupID = UUID().uuidString
    // 高亮组成员
    let highlight = PDFAnnotation(bounds: CGRect(x: 10, y: 20, width: 100, height: 12), forType: .highlight, withProperties: nil)
    highlight.color = NSColor(red: 1, green: 0.835, blue: 0.231, alpha: 1)
    highlight.userName = groupID
    page.addAnnotation(highlight)
    // 批注标记（/Text 图标，contents 为批注正文）
    let marker = PDFAnnotation(bounds: CGRect(x: 500, y: 30, width: 22, height: 22), forType: .text, withProperties: nil)
    marker.contents = "批注正文"
    marker.userName = groupID
    page.addAnnotation(marker)

    // 写 sidecar
    try SidecarAnnotationWriter(pdfURL: url).writeBack(document: document, to: url)
    let sidecarURL = SidecarAnnotationStorage.sidecarURL(for: url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

    // 重开新文档并从 sidecar 重建
    let reloaded = try XCTUnwrap(PDFDocument(url: url))
    let data = try Data(contentsOf: sidecarURL)
    let pairs = SidecarAnnotationStorage.annotations(from: data)
    XCTAssertEqual(pairs.count, 2)
    for (pageIndex, annotation) in pairs {
      reloaded.page(at: pageIndex)?.addAnnotation(annotation)
    }
    let annotations = try XCTUnwrap(reloaded.page(at: 0)).annotations
    // /Text 标记加回页面时 PDFKit 会自动伴随一个 Popup（与 App 内创建行为一致）
    let types = annotations.compactMap(\.type).filter { $0 != "Popup" }.sorted()
    XCTAssertEqual(types, ["Highlight", "Text"])
    let restoredMarker = try XCTUnwrap(annotations.first { $0.type == "Text" })
    XCTAssertEqual(restoredMarker.contents, "批注正文")
    XCTAssertEqual(restoredMarker.userName, groupID)
    let restoredHighlight = try XCTUnwrap(annotations.first { $0.type == "Highlight" })
    XCTAssertEqual(restoredHighlight.bounds, CGRect(x: 10, y: 20, width: 100, height: 12))
  }

  @MainActor
  func testWriteBackDoesNotTouchPDF() throws {
    let (url, document) = try makePDFFile()
    let originalData = try Data(contentsOf: url)
    let page = try XCTUnwrap(document.page(at: 0))
    page.addAnnotation(PDFAnnotation(bounds: .zero, forType: .highlight, withProperties: nil))

    try SidecarAnnotationWriter(pdfURL: url).writeBack(document: document, to: url)

    XCTAssertEqual(try Data(contentsOf: url), originalData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
  }

  @MainActor
  func testPopupExcludedFromSidecar() throws {
    let (url, document) = try makePDFFile()
    let page = try XCTUnwrap(document.page(at: 0))
    let popup = PDFAnnotationPopup(bounds: CGRect(x: 0, y: 0, width: 100, height: 60))
    page.addAnnotation(popup)
    let entries = SidecarAnnotationStorage.entries(for: document)
    XCTAssertTrue(entries.isEmpty)
  }

  @MainActor
  func testCorruptSidecarReturnsEmpty() {
    let pairs = SidecarAnnotationStorage.annotations(from: Data([0xFF, 0x00]))
    XCTAssertTrue(pairs.isEmpty)
  }

  @MainActor
  func testColorHexRoundTrip() {
    let color = NSColor(red: 0.455, green: 0.78, blue: 0.988, alpha: 1)
    let hex = SidecarAnnotationStorage.hexString(for: color)
    XCTAssertNotNil(hex)
    let restored = SidecarAnnotationStorage.color(for: hex!)
    let rgb = restored!.usingColorSpace(.deviceRGB)!
    XCTAssertEqual(rgb.redComponent, 0.455, accuracy: 0.01)
    XCTAssertEqual(rgb.greenComponent, 0.78, accuracy: 0.01)
    XCTAssertEqual(rgb.blueComponent, 0.988, accuracy: 0.01)
  }

  @MainActor
  func testSidecarModePersistsPerFile() throws {
    let suite = "SidecarAnnotationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let (url, document) = try makePDFFile()
    let store = PDFAnnotationStore(defaults: defaults)
    store.attach(document: document, url: url)
    XCTAssertFalse(store.isSidecarMode)
    store.setSidecarMode(true)
    XCTAssertTrue(store.isSidecarMode)

    // 新实例（模拟重启）恢复模式
    let reopened = PDFAnnotationStore(defaults: defaults)
    reopened.attach(document: try XCTUnwrap(PDFDocument(url: url)), url: url)
    XCTAssertTrue(reopened.isSidecarMode)
  }
}
