import PDFKit
import XCTest
@testable import MarkPDF

/// 标注列表缓存单测（FR-4.5 性能修复）：annotationItemsSnapshot 仅随 revision 重扫，
/// 重复读取与无关 @Published 变化（工具/色板/用色）不得触发全文档重扫
@MainActor
final class AnnotationItemsCacheTests: XCTestCase {
  private let suiteName = "AnnotationItemsCacheTests"
  private var dir: URL!
  private var store: PDFAnnotationStore!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AnnotationItemsCacheTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    store = PDFAnnotationStore(defaults: defaults)
  }

  override func tearDownWithError() throws {
    removeTestDefaultsSuite(suiteName, using: defaults)
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

  private func highlight(y: CGFloat) -> PDFAnnotation {
    let annotation = PDFAnnotation(
      bounds: NSRect(x: 10, y: y, width: 80, height: 12),
      forType: .highlight,
      withProperties: nil
    )
    annotation.color = .yellow
    return annotation
  }

  /// attach 恰好重扫一次并填满缓存；之后重复读缓存不再重扫
  func testSnapshotReadsDoNotRescan() {
    let (doc, url) = makeDocument()
    doc.page(at: 0)!.addAnnotation(highlight(y: 50))
    store.attach(document: doc, url: url)
    XCTAssertEqual(store.annotationItemsRescanCount, 1, "attach 应恰好重扫一次")
    XCTAssertEqual(store.annotationItemsSnapshot.count, 1, "attach 后缓存应立即可用")

    _ = store.annotationItemsSnapshot
    _ = store.annotationItemsSnapshot
    XCTAssertEqual(store.annotationItemsRescanCount, 1, "重复读缓存不得重扫")
  }

  /// 工具/色板/用色等 @Published 变化（原切色板即全文档双重重扫的根因）不得触发重扫
  func testUnrelatedPublishedChangesDoNotRescan() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    store.activeTool = .highlight
    store.paletteKind = .underline
    store.remember(color: .red, for: .highlight)
    store.activeTool = nil
    XCTAssertEqual(store.annotationItemsRescanCount, 1, "工具/色板/用色变化不得触发全文档重扫")
  }

  /// 标注变更经 revision 防抖合并刷新一次缓存（最终一致语义不变）
  func testMarkDirtyRefreshesSnapshotOnceAfterDebounce() async {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    let annotation = highlight(y: 50)
    store.add(annotation, to: page)
    store.remove(annotation, from: page)
    try? await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(store.annotationItemsRescanCount, 2, "防抖窗口内连续增删应合并为一次重扫")
    XCTAssertTrue(store.annotationItemsSnapshot.isEmpty, "增删抵消后缓存应为空")
  }

  /// 实时全扫入口保留：导出等场景直接改 PDFKit 文档（绕过 store）也能读到最新条目
  func testAnnotationItemsMethodScansLive() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    doc.page(at: 0)!.addAnnotation(highlight(y: 50))
    XCTAssertEqual(store.annotationItems().count, 1, "annotationItems() 应保持实时全扫语义")
  }
}
