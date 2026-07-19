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

  func testKindMappingCoversManagedKinds() {
    let cases: [(PDFAnnotationSubtype, AnnotationKind)] = [
      (.highlight, .highlight),
      (.underline, .underline),
      (.strikeOut, .strikeOut),
      (.freeText, .freeText),
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
    // 组 ID 必须是 UUID 形态（PDFKit 会自动把系统用户名写进 userName，不能误当组 ID）
    let groupID = UUID().uuidString
    for annotation in [
      highlight(y: 150, groupID: groupID),
      highlight(y: 130, groupID: groupID),
      highlight(y: 100), // 无组：独立条目
    ] {
      page.addAnnotation(annotation)
    }

    let items = store.annotationItems()
    XCTAssertEqual(items.count, 2)
    let grouped = items.first { $0.id == groupID }
    XCTAssertEqual(grouped?.annotations.count, 2)
    XCTAssertEqual(grouped?.pageLabel, 1)
    XCTAssertEqual(grouped?.kind, .highlight)
  }

  /// 作者名形态的 userName（PDFKit 自动填系统用户名/预览写作者名）不得并组
  func testAuthorNameUserNameDoesNotGroup() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    for annotation in [
      highlight(y: 150, groupID: "why"),
      highlight(y: 130, groupID: "why"),
    ] {
      page.addAnnotation(annotation)
    }
    XCTAssertEqual(store.annotationItems().count, 2, "同作者名的两条标注应保持独立条目")
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

  /// revision 刷新有 300ms 防抖（批注输入每键 markDirty 不能按键频全文档重扫）；
  /// 防抖窗口内的连续变更合并为一次刷新
  func testRevisionBumpsOnChanges() async {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let baseline = store.revision
    let page = doc.page(at: 0)!
    let annotation = highlight(y: 50)
    store.add(annotation, to: page)
    store.remove(annotation, from: page)
    try? await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(store.revision, baseline + 1, "防抖窗口内连续增删合并为一次 revision 刷新")
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
