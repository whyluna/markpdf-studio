import PDFKit
import SwiftUI
import XCTest
@testable import MarkPDF

@MainActor
final class PDFAnnotationRedrawTests: XCTestCase {
  func testOverlayMaintenanceKeepsToolbarsAndUnchangedCardsInTheirWindow() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let marker = PDFAnnotation(bounds: NSRect(x: 15, y: 250, width: 22, height: 22),
      forType: .text, withProperties: nil)
    marker.userName = UUID().uuidString
    marker.contents = "A comment that stays visible while scrolling"
    fixture.page.addAnnotation(marker)
    fixture.controller.rebuildCommentCards()
    let originalCards = fixture.overlay.subviews.filter { $0 is NSHostingView<CommentCardView> }.map(ObjectIdentifier.init)
    fixture.overlay.removedHostedViews = 0
    let begin = ProcessInfo.processInfo.systemUptime
    for _ in 0..<20 { fixture.controller.rebuildCommentCards() }
    let elapsed = (ProcessInfo.processInfo.systemUptime - begin) * 1000
    print("Overlay rebuild 20x: \(elapsed)ms, detached hosted views: \(fixture.overlay.removedHostedViews)")
    XCTAssertEqual(fixture.overlay.removedHostedViews, 0,
      "维护覆盖层的层级不应让工具条/未变卡片离开窗口，避免重新触发 SwiftUI 环境与窗口约束")
    XCTAssertEqual(fixture.overlay.subviews.filter { $0 is NSHostingView<CommentCardView> }.map(ObjectIdentifier.init), originalCards)
    // 删除仍及时清理旧卡片，并保留其他浮动面板。
    fixture.page.removeAnnotation(marker)
    fixture.controller.rebuildCommentCards()
    XCTAssertTrue(fixture.overlay.subviews.filter { $0 is NSHostingView<CommentCardView> }.isEmpty)
    XCTAssertEqual(fixture.overlay.removedHostedViews, 1)
  }

  func testTextAnnotationRefreshDoesNotInvalidatePDFPageRendering() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    // 普通划线已经由 PDFKit 在添加时更新自身标注层。随后 revision 引发的覆盖层重建
    // 不应再失效 PDF/documentView，让紧接着的滚动重新绘制正文。
    let annotation = PDFAnnotation(bounds: NSRect(x: 40, y: 180, width: 100, height: 15),
      forType: .underline, withProperties: nil)
    fixture.page.addAnnotation(annotation)
    fixture.view.redrawRequests = []
    fixture.view.changedPages = []
    fixture.controller.rebuildCommentCards()
    XCTAssertTrue(fixture.view.redrawRequests.isEmpty)
    XCTAssertTrue(fixture.view.changedPages.isEmpty)
  }

  func testUnchangedCommentRebuildDoesNotInvalidatePageAgain() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let marker = PDFAnnotation(bounds: NSRect(x: 15, y: 250, width: 22, height: 22),
      forType: .text, withProperties: nil)
    marker.userName = UUID().uuidString
    marker.contents = "Comment"
    fixture.page.addAnnotation(marker)
    fixture.controller.rebuildCommentCards()
    XCTAssertFalse(marker.shouldDisplay)
    XCTAssertTrue(fixture.view.changedPages.contains { $0 === fixture.page },
      "首次隐藏原生气泡仍需及时刷新该页")
    fixture.view.redrawRequests = []
    fixture.view.changedPages = []
    fixture.controller.rebuildCommentCards()
    XCTAssertTrue(fixture.view.redrawRequests.isEmpty)
    XCTAssertTrue(fixture.view.changedPages.isEmpty, "卡片内容/位置维护不使未改动正文失效")
  }

  func testNativeScrollNotificationsOnlyAffectTheirOwnPDF() async throws {
    var now: TimeInterval = 10
    let fixture = try Fixture(uptime: { now })
    defer { fixture.close() }
    let annotation = PDFAnnotation(bounds: NSRect(x: 40, y: 180, width: 100, height: 15),
      forType: .underline, withProperties: nil)
    fixture.store.add(annotation, to: fixture.page)
    let revision = fixture.store.revision
    // 普通鼠标只有 didLiveScroll，没有 willStart/didEnd，也必须生效。
    let scroll = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? NSScrollView }.first)
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    try await Task.sleep(nanoseconds: 650_000_000)
    XCTAssertEqual(fixture.store.revision, revision)
    // 手势结束后的惯性帧延长避让期。
    now += 0.15
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    now += 0.15
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertEqual(fixture.store.revision, revision)
    // 停止后另一个 PDF/AI 侧栏的滚动不会让本页保存一直等待。
    now += 1
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: NSScrollView())
    try await Task.sleep(nanoseconds: 450_000_000)
    XCTAssertEqual(fixture.store.revision, revision + 1)
  }

  private final class RecordingPDFView: PDFView {
    var redrawRequests: [NSRect] = []
    var changedPages: [PDFPage] = []
    override func setNeedsDisplay(_ invalidRect: NSRect) {
      redrawRequests.append(invalidRect)
      super.setNeedsDisplay(invalidRect)
    }
    override func annotationsChanged(on page: PDFPage) {
      changedPages.append(page)
      super.annotationsChanged(on: page)
    }
  }

  private final class TrackingOverlayHost: NSView {
    var removedHostedViews = 0
    override func willRemoveSubview(_ subview: NSView) {
      if subview is NSHostingView<SelectionFloatingPanel> || subview is NSHostingView<CommentCardView> {
        removedHostedViews += 1
      }
      super.willRemoveSubview(subview)
    }
  }

  @MainActor
  private final class Fixture {
    let view: RecordingPDFView
    let page: PDFPage
    let controller: AnnotationToolbarController
    let window: NSWindow
    let store: PDFAnnotationStore
    let defaults: UserDefaults
    let overlay: TrackingOverlayHost

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
      defaults = try XCTUnwrap(UserDefaults(suiteName: "PDFAnnotationRedrawTests"))
      defaults.removePersistentDomain(forName: "PDFAnnotationRedrawTests")
      store = PDFAnnotationStore(defaults: defaults, uptime: uptime)
      let document = PDFDocument()
      page = PDFPage()
      page.setBounds(NSRect(x: 0, y: 0, width: 400, height: 500), for: .mediaBox)
      document.insert(page, at: 0)
      view = RecordingPDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 650))
      window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let root = NSView(frame: view.frame)
      window.contentView = root
      root.addSubview(view)
      overlay = TrackingOverlayHost(frame: view.frame)
      root.addSubview(overlay)
      view.document = document
      view.autoScales = true
      view.layoutDocumentView()
      let settings = AISettingsStore(defaults: defaults)
      settings.update { $0.autoTranslateOnSelection = false }
      controller = AnnotationToolbarController(pdfView: view, overlayHost: overlay, store: store,
        aiSettings: settings, aiKeys: AIKeyStore(storage: InMemoryAIKeyStorage()))
      XCTAssertTrue(view.visiblePages.contains { $0 === page })
    }

    func close() {
      XCTAssertFalse(window.isVisible)
      window.close()
      removeTestDefaultsSuite("PDFAnnotationRedrawTests", using: defaults)
    }
  }
}
