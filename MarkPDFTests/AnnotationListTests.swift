import PDFKit
import XCTest
@testable import MarkPDF

/// FR-4.5 标注列表单测：子类型映射、同组合并、排序逻辑、revision 同步
@MainActor
final class AnnotationListTests: XCTestCase {
  private var dir: URL!
  private var store: PDFAnnotationStore!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AnnotationListTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    store = PDFAnnotationStore(defaults: UserDefaults(suiteName: "AnnotationListTests")!)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func makeDocument(pages: Int = 2) -> (PDFDocument, URL) {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let image = NSImage(size: NSSize(width: 200, height: 200))
    image.addRepresentation(rep)
    let doc = PDFDocument()
    for index in 0..<pages {
      doc.insert(PDFPage(image: image)!, at: index)
    }
    let url = dir.appendingPathComponent("\(UUID().uuidString).pdf")
    doc.write(to: url)
    return (doc, url)
  }

  private func highlight(y: CGFloat, groupID: String? = nil, color: NSColor = .yellow) -> PDFAnnotation {
    let annotation = PDFAnnotation(
      bounds: NSRect(x: 10, y: y, width: 80, height: 12),
      forType: .highlight,
      withProperties: nil
    )
    annotation.userName = groupID
    annotation.color = color
    return annotation
  }

  // MARK: - 子类型映射

  func testKindMappingCoversMarkupAndShapes() {
    let cases: [(PDFAnnotationSubtype, AnnotationKind)] = [
      (.highlight, .highlight),
      (.underline, .underline),
      (.strikeOut, .strikeOut),
      (.freeText, .freeText),
      (.ink, .ink),
    ]
    for (subtype, expected) in cases {
      let annotation = PDFAnnotation(bounds: .zero, forType: subtype, withProperties: nil)
      XCTAssertEqual(AnnotationKind.of(annotation), expected, "\(subtype.rawValue) 应映射为 \(expected)")
    }
  }

  func testPopupAnnotationIsNotManaged() {
    let popup = PDFAnnotation(bounds: .zero, forType: .text, withProperties: nil)
    XCTAssertNil(AnnotationKind.of(popup), "Text/便签已从产品移除，不应进入列表")
  }

  // MARK: - 列表快照

  func testSameGroupAnnotationsMergeIntoOneItem() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    for annotation in [
      highlight(y: 150, groupID: "g1"),
      highlight(y: 130, groupID: "g1"),
      highlight(y: 100), // 无组：独立条目
    ] {
      page.addAnnotation(annotation)
    }

    let items = store.annotationItems()
    XCTAssertEqual(items.count, 2)
    let grouped = items.first { $0.id == "g1" }
    XCTAssertEqual(grouped?.annotations.count, 2)
    XCTAssertEqual(grouped?.pageLabel, 1)
    XCTAssertEqual(grouped?.kind, .highlight)
  }

  func testPopupCompanionIsExcludedFromItems() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    // PDFKit 添加 /Text 便签会自动补 Popup 伴侣，两者都不应出现在列表
    let note = PDFAnnotation(bounds: NSRect(x: 150, y: 150, width: 22, height: 22), forType: .text, withProperties: nil)
    page.addAnnotation(note)
    page.addAnnotation(highlight(y: 50))
    XCTAssertEqual(store.annotationItems().count, 1)
  }

  func testRevisionBumpsOnChanges() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let baseline = store.revision
    let page = doc.page(at: 0)!
    let annotation = highlight(y: 50)
    store.add(annotation, to: page)
    XCTAssertEqual(store.revision, baseline + 1)
    store.remove(annotation, from: page)
    XCTAssertEqual(store.revision, baseline + 2)
  }

  // MARK: - 排序

  private func item(pageIndex: Int, y: CGFloat = 100, kind: AnnotationKind = .highlight, color: NSColor = .yellow) -> AnnotationItem {
    let annotation = PDFAnnotation(bounds: NSRect(x: 10, y: y, width: 80, height: 12), forType: .highlight, withProperties: nil)
    return AnnotationItem(
      id: UUID().uuidString,
      annotations: [annotation],
      kind: kind,
      color: color,
      pageIndex: pageIndex,
      excerpt: "",
      name: ""
    )
  }

  func testSortByPageThenVisualOrder() {
    let items = [
      item(pageIndex: 2),
      item(pageIndex: 1, y: 100),
      item(pageIndex: 1, y: 150), // 同页 y 大者（更靠上）排前
    ]
    let sorted = AnnotationSort.page.sort(items)
    XCTAssertEqual(sorted[0].pageIndex, 1)
    XCTAssertEqual(sorted[0].annotations.first?.bounds.maxY, 162)
    XCTAssertEqual(sorted[1].pageIndex, 1)
    XCTAssertEqual(sorted[2].pageIndex, 2)
  }

  func testSortByColor() {
    let items = [
      item(pageIndex: 1, color: AnnotationColor.red.nsColor),
      item(pageIndex: 2, color: AnnotationColor.yellow.nsColor),
      item(pageIndex: 3, color: AnnotationColor.green.nsColor),
    ]
    let sorted = AnnotationSort.color.sort(items)
    XCTAssertEqual(sorted.map(\.pageIndex), [2, 3, 1], "应黄→绿→红（色板序）")
  }

  func testSortByType() {
    let items = [
      item(pageIndex: 1, kind: .strikeOut),
      item(pageIndex: 2, kind: .highlight),
      item(pageIndex: 3, kind: .underline),
    ]
    let sorted = AnnotationSort.type.sort(items)
    XCTAssertEqual(sorted.map(\.kind), [.highlight, .underline, .strikeOut])
  }
}
