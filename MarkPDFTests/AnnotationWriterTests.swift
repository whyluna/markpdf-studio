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

  /// FR-4.3 批注：/Text 标记图标 + 高亮虚线段（同组）写回后内容与分组保留
  /// （PDFKit 不渲染程序化 Line 标注，虚线用细长小高亮矩形拼出）
  func testCommentAnnotationRoundTrip() throws {
    let (doc, url) = try makePDF(named: "comment.pdf")
    let page = doc.page(at: 0)!
    let groupID = UUID().uuidString

    let marker = PDFAnnotation(
      bounds: NSRect(x: 4, y: 129, width: 22, height: 22),
      forType: .text,
      withProperties: nil
    )
    marker.iconType = .comment
    marker.contents = "这一段与 §3 矛盾，需要复核"
    marker.userName = groupID
    page.addAnnotation(marker)

    var dashX: CGFloat = 26
    while dashX < 60 {
      let dash = PDFAnnotation(
        bounds: NSRect(x: dashX, y: 139.4, width: min(4, 60 - dashX), height: 1.2),
        forType: .highlight,
        withProperties: nil
      )
      dash.color = .systemBlue
      dash.userName = groupID
      page.addAnnotation(dash)
      dashX += 6.5
    }

    try writer.writeBack(document: doc, to: url)

    let reopened = PDFDocument(url: url)
    let annotations = reopened?.page(at: 0)?.annotations ?? []
    let markers = annotations.filter { $0.isCommentMarker }
    XCTAssertEqual(markers.count, 1)
    XCTAssertEqual(markers.first?.contents, "这一段与 §3 矛盾，需要复核")
    XCTAssertEqual(markers.first?.userName, groupID)
    let dashes = annotations.filter {
      ($0.type == "Highlight" || $0.type == "/Highlight") && $0.userName == groupID
    }
    XCTAssertEqual(dashes.count, 6, "虚线段应与标记同组（整体删除/列表合并）")
  }

  // MARK: - 降级路径失败保留救援文件（回归）

  /// 注入用 FileManager：replaceItemAt（经 ObjC 底层 replaceItem(at:...resultingItemURL:)）
  /// 与 moveItem 强制失败，确定性地驱动写回进入降级路径并在 moveItem 处失败
  private final class ReplaceAndMoveFailFileManager: FileManager {
    override func replaceItem(
      at originalItemURL: URL,
      withItemAt newItemURL: URL,
      backupItemName: String?,
      options: FileManager.ItemReplacementOptions,
      resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
      throw CocoaError(.fileWriteVolumeReadOnly)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
      throw CocoaError(.fileWriteVolumeReadOnly)
    }
  }

  /// 回归：降级路径 moveItem 失败时必须保留 tmp——原文件已被降级路径移除，
  /// tmp 是唯一含最新标注的完整副本（此前 defer 无条件清理会连 tmp 一起删掉，标注全部丢失）
  func testFallbackMoveFailurePreservesTmpRescueFile() throws {
    let (doc, url) = try makePDF(named: "rescue.pdf")
    doc.page(at: 0)?.addAnnotation(highlightAnnotation())

    let failingWriter = LiveAnnotationWriter(fileManager: ReplaceAndMoveFailFileManager())
    XCTAssertThrowsError(try failingWriter.writeBack(document: doc, to: url))

    // 最坏场景：原文件已被降级路径移除，tmp 必须保留且为含标注的完整 PDF（救援文件）
    let tmpURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).tmp")
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path), "降级失败必须保留 tmp 救援文件")
    let rescued = PDFDocument(url: tmpURL)
    XCTAssertEqual(rescued?.page(at: 0)?.annotations.count ?? -1, 1, "tmp 应为含最新标注的完整 PDF")
  }

  // MARK: - 后台副本写回（主线程不做重绘）

  private func linkAnnotation() -> PDFAnnotation {
    let annotation = PDFAnnotation(
      bounds: NSRect(x: 10, y: 150, width: 100, height: 12),
      forType: .link,
      withProperties: nil
    )
    annotation.action = PDFActionURL(url: URL(string: "https://example.com/paper")!)
    return annotation
  }

  /// 落盘在后台副本上做：从磁盘现状重开一份、只重放本应用管理的标注。
  /// PDF 自带的超链接不经重建流程（重建只保 bounds/颜色/内容，会丢动作），须原样保留
  func testForeignAnnotationsSurviveWriteBack() throws {
    let (base, url) = try makePDF(named: "foreign.pdf")
    base.page(at: 0)?.addAnnotation(linkAnnotation())
    XCTAssertTrue(base.write(to: url))

    let doc = try XCTUnwrap(PDFDocument(url: url))
    let highlight = highlightAnnotation()
    highlight.userName = UUID().uuidString
    doc.page(at: 0)?.addAnnotation(highlight)
    try writer.writeBack(document: doc, to: url)

    let annotations = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.annotations)
    let links = annotations.filter { $0.type == "Link" || $0.type == "/Link" }
    XCTAssertEqual(links.count, 1, "外来超链接必须保留")
    XCTAssertEqual((links.first?.action as? PDFActionURL)?.url?.absoluteString, "https://example.com/paper")
    XCTAssertEqual(annotations.filter(\.isAppManaged).count, 1, "本应用标注写入一条")
  }

  /// 反复写回不重复堆积（先摘上次写进去的本应用标注，再按快照重放）
  func testRepeatedWriteBackDoesNotDuplicate() throws {
    let (doc, url) = try makePDF(named: "repeat.pdf")
    doc.page(at: 0)?.addAnnotation(highlightAnnotation())

    try writer.writeBack(document: doc, to: url)
    try writer.writeBack(document: doc, to: url)
    try writer.writeBack(document: doc, to: url)

    XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.count, 1, "三次写回仍只有一条")
  }

  /// 删除能落地：快照里没有的标注不会从磁盘旧版本里被带回来
  func testDeletionPropagatesToFile() throws {
    let (base, url) = try makePDF(named: "delete.pdf")
    base.page(at: 0)?.addAnnotation(linkAnnotation())
    XCTAssertTrue(base.write(to: url))

    let doc = try XCTUnwrap(PDFDocument(url: url))
    let highlight = highlightAnnotation()
    doc.page(at: 0)?.addAnnotation(highlight)
    try writer.writeBack(document: doc, to: url)
    XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.filter(\.isAppManaged).count, 1)

    doc.page(at: 0)?.removeAnnotation(highlight)
    try writer.writeBack(document: doc, to: url)

    let annotations = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.annotations)
    XCTAssertEqual(annotations.filter(\.isAppManaged).count, 0, "删除必须落地")
    XCTAssertEqual(annotations.filter { $0.type == "Link" || $0.type == "/Link" }.count, 1, "外来标注仍在")
  }

  /// 批注标记经重建后仍是便签图标（iconType 不带在快照字段里，须按类型补回）
  func testCommentMarkerIconSurvivesRebuild() throws {
    let (doc, url) = try makePDF(named: "icon.pdf")
    let marker = PDFAnnotation(
      bounds: NSRect(x: 4, y: 129, width: 22, height: 22),
      forType: .text,
      withProperties: nil
    )
    marker.iconType = .comment
    marker.contents = "图标回归"
    marker.userName = UUID().uuidString
    doc.page(at: 0)?.addAnnotation(marker)

    try writer.writeBack(document: doc, to: url)

    let reopened = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.annotations)
    let markers = reopened.filter(\.isCommentMarker)
    XCTAssertEqual(markers.count, 1)
    XCTAssertEqual(markers.first?.iconType, .comment)
    XCTAssertEqual(markers.first?.contents, "图标回归")
  }
}
