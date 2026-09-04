import PDFKit
import SwiftUI
import XCTest
@testable import MarkPDF

/// 划词分栏裁剪（双栏论文右栏划词不带左栏）与翻译源文本整理
final class SelectionColumnTrimmerTests: XCTestCase {
  /// 构造双栏行集：左栏 x 40–260、右栏 x 300–520，各 4 行
  private func twoColumnBounds() -> [CGRect] {
    var rects: [CGRect] = []
    for i in 0..<4 {
      rects.append(CGRect(x: 40, y: 100 - i * 20, width: 220, height: 12))
    }
    for i in 0..<4 {
      rects.append(CGRect(x: 300, y: 100 - i * 20, width: 220, height: 12))
    }
    return rects
  }

  func testDragWithinRightColumnKeepsOnlyRightColumnLines() {
    let bounds = twoColumnBounds()
    // 起止都在右栏（x≈400）
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 400, y: 95),
      dragEnd: NSPoint(x: 420, y: 30)
    )
    XCTAssertEqual(kept, [4, 5, 6, 7], "右栏拖拽只保留右栏 4 行")
  }

  func testDragWithinLeftColumnKeepsOnlyLeftColumnLines() {
    let bounds = twoColumnBounds()
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 100, y: 30),
      dragEnd: NSPoint(x: 60, y: 95)
    )
    XCTAssertEqual(kept, [0, 1, 2, 3])
  }

  func testCrossColumnDragKeepsEverything() {
    let bounds = twoColumnBounds()
    // 顺向跨栏（左栏→右栏，阅读顺序）：有意跨栏复制，保持原选区
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 100, y: 30),
      dragEnd: NSPoint(x: 400, y: 95)
    )
    XCTAssertEqual(kept, Array(bounds.indices))
  }

  func testBackwardCrossColumnDragKeepsEverything() {
    let bounds = twoColumnBounds()
    // 逆向跨栏（右栏→左栏）同样视为有意跨栏保持原选区：缩进/公式会聚成伪栏，
    // 「裁到起始栏」会让栏内向左回拖被误裁（该规则已回退，此为回归用例）
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 400, y: 95),
      dragEnd: NSPoint(x: 100, y: 30)
    )
    XCTAssertEqual(kept, Array(bounds.indices))
  }

  func testSingleColumnKeepsEverything() {
    let bounds = [CGRect(x: 40, y: 0, width: 200, height: 12),
      CGRect(x: 40, y: 20, width: 200, height: 12)]
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 100, y: 25),
      dragEnd: NSPoint(x: 100, y: 5)
    )
    XCTAssertEqual(kept, [0, 1])
  }

  func testEndpointOutsideColumnsKeepsEverything() {
    let bounds = twoColumnBounds()
    // 起点在栏间空白/图区（x 不落入任何栏）
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 278, y: 95),
      dragEnd: NSPoint(x: 400, y: 30)
    )
    XCTAssertEqual(kept, Array(bounds.indices))
  }

  // MARK: - 源文本整理

  func testNormalizerJoinsPhysicalLines() {
    XCTAssertEqual(
      TranslationTextNormalizer.normalize("the KV cache is managed is critical\nin determining\nthe maximum batch size"),
      "the KV cache is managed is critical in determining the maximum batch size"
    )
  }

  func testNormalizerDehyphenates() {
    XCTAssertEqual(
      TranslationTextNormalizer.normalize("informa-\ntion frag-\nmentation"),
      "information fragmentation"
    )
  }

  func testNormalizerCollapsesWhitespace() {
    XCTAssertEqual(
      TranslationTextNormalizer.normalize("  a  b \n\n c "),
      "a b c"
    )
  }

  func testNormalizerEmpty() {
    XCTAssertEqual(TranslationTextNormalizer.normalize(" \n "), "")
  }
}

/// 隐藏窗口内验证真正的 PDFSelection、控制器事件入口与工具条动作，不操作用户窗口。
@MainActor
final class SelectionToolbarEventTests: XCTestCase {
  func testToolbarClickPreservesWrappedSelectionAndAppliesBothLines() async throws {
    for kind in [AnnotationKind.underline, .highlight, .strikeOut] {
      let fixture = try SelectionToolbarFixture()
      defer { fixture.close() }
      try fixture.completeSelection()
      await drainMainQueue()
      let panel = try fixture.panel()
      XCTAssertFalse(panel.isHidden)
      let beforeFrame = panel.frame
      let beforeText = fixture.pdfView.currentSelection?.string
      let point = fixture.viewport.overlayHost.convert(
        NSPoint(x: panel.frame.midX - 30, y: panel.frame.maxY - 18), to: nil)
      let content = try XCTUnwrap(fixture.window.contentView)
      let hitPoint = content.superview?.convert(point, from: nil) ?? point
      let hit = try XCTUnwrap(content.hitTest(hitPoint))
      XCTAssertTrue(hit === panel || hit.isDescendant(of: panel), "确保模拟点真实命中工具条而非正文")
      XCTAssertEqual(SelectionColumnTrimmer.keptLineIndices(
        lineBounds: fixture.selection.selectionsByLine().map { $0.bounds(for: fixture.page) }
          .sorted { $0.midY > $1.midY },
        dragStart: fixture.pdfView.convert(fixture.pdfView.convert(fixture.start, from: nil), to: fixture.page),
        dragEnd: fixture.pdfView.convert(fixture.pdfView.convert(point, from: nil), to: fixture.page)),
        [0], "旧实现误用本次工具条坐标时，确实会把这个选区裁成一行")
      fixture.controller.handleSelectionMouseEvent(try fixture.event(.leftMouseDown, at: point))
      fixture.controller.handleSelectionMouseEvent(try fixture.event(.leftMouseUp, at: point))
      await drainMainQueue()
      XCTAssertEqual(fixture.pdfView.currentSelection?.string, beforeText)
      XCTAssertEqual(fixture.pdfView.currentSelection?.selectionsByLine().count, 2)
      XCTAssertEqual(panel.frame, beforeFrame, "工具条自己的点击不能在分派前移动按钮")
      // 使用生产工具条的同一个按钮回调，验证首次动作创建两行同组标注。
      panel.rootView.onApply(kind)
      XCTAssertEqual(fixture.page.annotations.filter { AnnotationKind.of($0) == kind }.count, 2)
      XCTAssertEqual(Set(fixture.page.annotations.compactMap(\.userName)).count, 1)
      XCTAssertNil(fixture.pdfView.currentSelection)
      XCTAssertFalse(fixture.window.isVisible)
    }
  }

  func testSidebarAndOtherPDFClicksCannotApplyActiveToolToOldSelection() async throws {
    let fixture = try SelectionToolbarFixture()
    defer { fixture.close() }
    let otherPDF = PDFView(frame: NSRect(x: 720, y: 30, width: 160, height: 620))
    fixture.window.contentView!.addSubview(otherPDF)
    fixture.store.activeTool = .underline
    fixture.pdfView.setCurrentSelection(fixture.selection, animate: false)
    for point in [NSPoint(x: 25, y: 300), NSPoint(x: 800, y: 300)] {
      fixture.controller.handleSelectionMouseEvent(try fixture.event(.leftMouseDown, at: point))
      fixture.controller.handleSelectionMouseEvent(try fixture.event(.leftMouseUp, at: point))
      await drainMainQueue()
      XCTAssertTrue(fixture.page.annotations.isEmpty)
      XCTAssertEqual(fixture.pdfView.currentSelection?.selectionsByLine().count, 2)
    }
  }

  func testActiveToolAppliesRealDragOnceUsingItsOwnEndpoints() async throws {
    let fixture = try SelectionToolbarFixture()
    defer { fixture.close() }
    fixture.store.activeTool = .underline
    try fixture.completeSelection(reverse: true)
    await drainMainQueue()
    XCTAssertEqual(fixture.page.annotations.count, 2)
    // 已消费的松手事件不可重复用于之后的选区。
    fixture.pdfView.setCurrentSelection(fixture.selection, animate: false)
    fixture.controller.handleSelectionMouseEvent(try fixture.event(.leftMouseUp, at: fixture.end))
    await drainMainQueue()
    XCTAssertEqual(fixture.page.annotations.count, 2)
    XCTAssertEqual(fixture.pdfView.currentSelection?.selectionsByLine().count, 2)
  }

  func testNewMouseDownCancelsDeferredSelectionCompletion() async throws {
    let fixture = try SelectionToolbarFixture()
    defer { fixture.close() }
    fixture.store.activeTool = .underline
    try fixture.completeSelection()
    fixture.controller.handleSelectionMouseEvent(
      try fixture.event(.leftMouseDown, at: NSPoint(x: 25, y: 300)))
    await drainMainQueue()
    XCTAssertTrue(fixture.page.annotations.isEmpty)
    XCTAssertEqual(fixture.pdfView.currentSelection?.selectionsByLine().count, 2)
  }

  func testRealSameColumnGestureStillTrimsOtherColumn() async throws {
    let fixture = try SelectionToolbarFixture()
    defer { fixture.close() }
    fixture.controller.handleSelectionMouseEvent(try fixture.event(.leftMouseDown, at: fixture.start))
    fixture.pdfView.setCurrentSelection(fixture.selection, animate: false)
    // 起止 x 同在右侧，模拟 PDFKit 连带选到左栏；真实选词仍保留原有裁栏能力。
    let rightEnd = NSPoint(x: fixture.start.x + 30, y: fixture.end.y)
    fixture.controller.handleSelectionMouseEvent(try fixture.event(.leftMouseUp, at: rightEnd))
    await drainMainQueue()
    XCTAssertEqual(fixture.pdfView.currentSelection?.selectionsByLine().count, 1)
    XCTAssertTrue(fixture.pdfView.currentSelection?.string?.contains("TAIL") == true)
  }

  func testChangingDocumentCancelsDeferredSelectionCompletion() async throws {
    let fixture = try SelectionToolbarFixture()
    defer { fixture.close() }
    fixture.store.activeTool = .underline
    try fixture.completeSelection()
    fixture.pdfView.document = PDFDocument()
    await drainMainQueue()
    XCTAssertTrue(fixture.page.annotations.isEmpty)
  }

  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }
}

@MainActor
private final class SelectionToolbarFixture {
  let window: NSWindow
  let viewport: PDFViewportView
  let page: PDFPage
  let selection: PDFSelection
  let store: PDFAnnotationStore
  let controller: AnnotationToolbarController
  let start: NSPoint
  let end: NSPoint
  let defaults: UserDefaults
  var pdfView: PDFView { viewport.pdfView }

  init() throws {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 560, height: 600)
    let consumer = try XCTUnwrap(CGDataConsumer(data: data))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let tail = "TAIL SELECTED FIRST LINE WITH MORE WORDS"
    let head = "HEAD"
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
    ("Unselected prefix" as NSString).draw(at: NSPoint(x: 40, y: 500), withAttributes: attributes)
    (tail as NSString).draw(at: NSPoint(x: 210, y: 500), withAttributes: attributes)
    (head as NSString).draw(at: NSPoint(x: 40, y: 470), withAttributes: attributes)
    ("Unselected remainder of second line" as NSString).draw(at: NSPoint(x: 120, y: 470), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    let document = try XCTUnwrap(PDFDocument(data: data as Data))
    let page = try XCTUnwrap(document.page(at: 0))
    self.page = page
    let source = try XCTUnwrap(page.string) as NSString
    let tailRange = source.range(of: tail)
    let headRange = source.range(of: head)
    XCTAssertNotEqual(tailRange.location, NSNotFound)
    XCTAssertNotEqual(headRange.location, NSNotFound)
    selection = PDFSelection(document: document)
    selection.add(try XCTUnwrap(page.selection(for: tailRange)))
    selection.add(try XCTUnwrap(page.selection(for: headRange)))
    // PDFKit 不保证组合选区的 selectionsByLine 顺序，测试按可视位置建立拖拽端点。
    let lines = selection.selectionsByLine().sorted { $0.bounds(for: page).midY > $1.bounds(for: page).midY }
    XCTAssertEqual(lines.count, 2)
    let first = lines[0].bounds(for: page)
    let second = lines[1].bounds(for: page)
    XCTAssertGreaterThan(first.minX, second.maxX + SelectionColumnTrimmer.clusterGap)
    // 复现条件：两段不重叠的水平范围本来属于连续两行，旧算法用按钮 x 会误裁为一行。
    XCTAssertEqual(SelectionColumnTrimmer.keptLineIndices(
      lineBounds: [first, second], dragStart: NSPoint(x: first.minX + 2, y: first.midY),
      dragEnd: NSPoint(x: first.midX, y: second.minY - 25)), [0])

    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    window.contentView = root
    viewport = PDFViewportView(frame: NSRect(x: 110, y: 30, width: 600, height: 620))
    root.addSubview(viewport)
    viewport.pdfView.document = document
    viewport.pdfView.autoScales = false
    viewport.pdfView.scaleFactor = 1
    viewport.pdfView.layoutDocumentView()
    start = viewport.pdfView.convert(viewport.pdfView.convert(
      NSPoint(x: first.minX + 2, y: first.midY), from: page), to: nil)
    end = viewport.pdfView.convert(viewport.pdfView.convert(
      NSPoint(x: second.maxX - 2, y: second.midY), from: page), to: nil)
    defaults = try XCTUnwrap(UserDefaults(suiteName: "SelectionToolbarEventTests"))
    defaults.removePersistentDomain(forName: "SelectionToolbarEventTests")
    let settings = AISettingsStore(defaults: defaults)
    settings.update { $0.autoTranslateOnSelection = false }
    store = PDFAnnotationStore(defaults: defaults)
    // 不 attach 用户路径；测试标注仅留在内存，Key 使用内存实现且不触发翻译。
    controller = AnnotationToolbarController(pdfView: viewport.pdfView, overlayHost: viewport.overlayHost,
      store: store, aiSettings: settings, aiKeys: AIKeyStore(storage: InMemoryAIKeyStorage()))
  }

  func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
  }

  func completeSelection(reverse: Bool = false) throws {
    controller.handleSelectionMouseEvent(try event(.leftMouseDown, at: reverse ? end : start))
    pdfView.setCurrentSelection(selection, animate: false)
    controller.handleSelectionMouseEvent(try event(.leftMouseUp, at: reverse ? start : end))
  }

  func panel() throws -> NSHostingView<SelectionFloatingPanel> {
    try XCTUnwrap(viewport.overlayHost.subviews.compactMap { $0 as? NSHostingView<SelectionFloatingPanel> }.first)
  }

  func close() {
    window.close()
    removeTestDefaultsSuite("SelectionToolbarEventTests", using: defaults)
  }
}
