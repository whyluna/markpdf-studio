import PDFKit
import XCTest
@testable import MarkPDF

/// FR-4.6 标注写回单测：.bak 一次性备份、原子写回、标注随文档落盘
final class AnnotationWriterTests: XCTestCase {
  private var dir: URL!
  private var writer: LiveAnnotationWriter!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AnnotationWriterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    writer = LiveAnnotationWriter()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  /// 构造一页空白 PDF 并落盘（NSImage 需含真实位图内容，否则 PDFPage 拒绝）
  private func makePDF(named name: String) throws -> (document: PDFDocument, url: URL) {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 200,
      pixelsHigh: 200,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )!
    let image = NSImage(size: NSSize(width: 200, height: 200))
    image.addRepresentation(rep)
    let doc = PDFDocument()
    let page = PDFPage(image: image)!
    doc.insert(page, at: 0)
    let url = dir.appendingPathComponent(name)
    XCTAssertTrue(doc.write(to: url))
    return (doc, url)
  }

  private func highlightAnnotation() -> PDFAnnotation {
    PDFAnnotation(
      bounds: NSRect(x: 10, y: 10, width: 80, height: 20),
      forType: .highlight,
      withProperties: nil
    )
  }

  func testWriteBackCreatesBakOnce() throws {
    let (doc, url) = try makePDF(named: "a.pdf")
    let bakURL = url.appendingPathExtension("bak")
    XCTAssertFalse(FileManager.default.fileExists(atPath: bakURL.path))

    try writer.writeBack(document: doc, to: url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: bakURL.path), "首次写回应创建 .bak")

    // .bak 内容应与写回前一致（不含标注）
    let bakDoc = PDFDocument(url: bakURL)
    XCTAssertEqual(bakDoc?.page(at: 0)?.annotations.count ?? -1, 0)

    // 二次写回不得覆盖既有 .bak（保留最原始文件）
    doc.page(at: 0)?.addAnnotation(highlightAnnotation())
    try writer.writeBack(document: doc, to: url)
    let bakDoc2 = PDFDocument(url: bakURL)
    XCTAssertEqual(bakDoc2?.page(at: 0)?.annotations.count ?? -1, 0, ".bak 必须保持首次备份内容")
  }

  func testWriteBackPersistsAnnotations() throws {
    let (doc, url) = try makePDF(named: "b.pdf")
    let annotation = highlightAnnotation()
    doc.page(at: 0)?.addAnnotation(annotation)

    try writer.writeBack(document: doc, to: url)

    let reopened = PDFDocument(url: url)
    let annotations = reopened?.page(at: 0)?.annotations ?? []
    XCTAssertEqual(annotations.count, 1)
    XCTAssertEqual(annotations.first?.type, annotation.type)
    XCTAssertEqual(annotations.first?.bounds, annotation.bounds)
  }

  func testNoTempFileLeftBehind() throws {
    let (doc, url) = try makePDF(named: "c.pdf")
    try writer.writeBack(document: doc, to: url)
    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertFalse(contents.contains { $0.hasSuffix(".tmp") }, "不应残留临时文件")
  }
}
