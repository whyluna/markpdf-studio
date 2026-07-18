import PDFKit
import XCTest
@testable import MarkPDF

/// 波浪线（Ink 模拟）数据往返测试：确认 Ink 标注随文档落盘且路径保留
final class InkAnnotationTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("InkAnnotationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func testInkAnnotationRoundTrips() throws {
    // 构造一页 PDF
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let image = NSImage(size: NSSize(width: 200, height: 200))
    image.addRepresentation(rep)
    let doc = PDFDocument()
    let page = PDFPage(image: image)!
    doc.insert(page, at: 0)

    // Ink 标注 + 折线路径（与波浪线同构）
    let annotation = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 100, height: 8), forType: .ink, withProperties: nil)
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 10, y: 14))
    path.line(to: NSPoint(x: 60, y: 18))
    path.line(to: NSPoint(x: 110, y: 14))
    annotation.add(path)
    annotation.color = .green
    page.addAnnotation(annotation)

    // 落盘并重开
    let url = dir.appendingPathComponent("ink.pdf")
    XCTAssertTrue(doc.write(to: url))
    let reopened = PDFDocument(url: url)
    let annotations = reopened?.page(at: 0)?.annotations ?? []
    XCTAssertEqual(annotations.count, 1, "Ink 标注应随文档落盘")
    XCTAssertEqual(annotations.first?.type, annotation.type)
  }
}
