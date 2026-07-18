import PDFKit
import SwiftUI

/// 支持捏合缩放的 PDFView（FR-3.2）。
/// 走响应链 `magnify(with:)` 通道：不占用手势识别器，避免与 PDFView 内部手势互斥
/// （此前 NSMagnificationGestureRecognizer 方案时好时坏、忽而失效的根因）。
final class ZoomablePDFView: PDFView {
  /// 捏合事件回调（事件阶段 + 当次增量），由 Coordinator 接管
  var onMagnify: ((_ phase: NSEvent.Phase, _ magnification: CGFloat) -> Void)?

  /// 手型光标区域（视图坐标）：命中时显示手型并屏蔽 PDFKit 的文本 I 形光标
  /// （用于浮动按钮——PDFView 会按文字命中把光标抢设为 I 形，必须在 PDFKit 管线内拦截）
  var handCursorRects: [CGRect] = []

  override func magnify(with event: NSEvent) {
    onMagnify?(event.phase, event.magnification)
  }

  override func cursorUpdate(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if handCursorRects.contains(where: { $0.contains(point) }) {
      NSCursor.pointingHand.set()
      return
    }
    super.cursorUpdate(with: event)
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if handCursorRects.contains(where: { $0.contains(point) }) {
      NSCursor.pointingHand.set()
      return
    }
    super.mouseMoved(with: event)
  }
}

/// PDF 阅读视图（FR-3.1/3.2）：系统 PDFKit 渲染，连续滚动；
/// 缩放支持按钮/快捷键（Store 驱动）与触控板捏合，范围 50%–400%。
/// 高亮 / 下划线等标注能力（FR-4.x）将在 M2 叠加在此视图之上。
struct PDFReaderView: NSViewRepresentable {
  let url: URL
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @EnvironmentObject private var annotationStore: PDFAnnotationStore

  func makeNSView(context: Context) -> PDFView {
    let pdfView = ZoomablePDFView()
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.autoScales = true
    pdfView.document = PDFDocument(url: url)
    pdfView.onMagnify = { [weak coordinator = context.coordinator] phase, magnification in
      coordinator?.handleMagnify(phase: phase, magnification: magnification)
    }

    // 点击认领焦点：分栏双 PDF 时，缩放/搜索作用于最近点击的视图（FR-1.4）。
    // delaysPrimaryMouseButtonEvents=false：不拦截鼠标事件，否则 PDFView 收不到
    // mouseDown，文本选区点击别处无法取消
    let click = NSClickGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.claimFocus(_:))
    )
    click.delaysPrimaryMouseButtonEvents = false
    pdfView.addGestureRecognizer(click)

    let center = NotificationCenter.default
    center.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.pageChanged(_:)),
      name: .PDFViewPageChanged,
      object: pdfView
    )
    center.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.scaleChanged(_:)),
      name: .PDFViewScaleChanged,
      object: pdfView
    )
    context.coordinator.pdfView = pdfView
    pdfStore.pdfView = pdfView
    context.coordinator.syncPageState()
    // 划词浮动工具条（FR-4.1）与标注写回关联（FR-4.6）
    context.coordinator.toolbarController = AnnotationToolbarController(
      pdfView: pdfView,
      store: annotationStore
    )
    if let document = pdfView.document {
      annotationStore.attach(document: document, url: url)
    }
    return pdfView
  }

  func updateNSView(_ pdfView: PDFView, context: Context) {
    if pdfView.document?.documentURL != url {
      pdfView.document = PDFDocument(url: url)
      // 新文档回到自适应宽度；切换标注写回关联
      pdfView.autoScales = true
      context.coordinator.syncPageState()
      if let document = pdfView.document {
        annotationStore.attach(document: document, url: url)
      }
      return
    }
    // 外部驱动的目标缩放（按钮/快捷键）；手动缩放时脱离自适应
    if abs(pdfView.scaleFactor - pdfStore.scale) > 0.001 {
      pdfView.autoScales = false
      pdfView.scaleFactor = PDFReaderStore.clamped(pdfStore.scale)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(coordinator)
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: PDFReaderView
    weak var pdfView: PDFView?
    /// 划词浮动工具条控制器（FR-4.1）
    var toolbarController: AnnotationToolbarController?
    /// 捏合手势进行中（此时不回写 Store，避免逐帧触发 SwiftUI 重渲染）
    private var isPinching = false
    /// 手势期间临时收起的文本选区（结束后恢复）
    private var savedSelection: PDFSelection?
    /// 手势起始缩放倍率
    private var pinchStartScale: CGFloat = 1
    /// 手势累计放大倍率
    private var pinchTotalMagnification: CGFloat = 1
    /// 缩放锚点：视图中心对应的文档点（保持缩放围绕中心而非角落）
    private var anchorPage: PDFPage?
    private var anchorDocPoint: CGPoint?

    init(_ parent: PDFReaderView) {
      self.parent = parent
    }

    /// 同步页码/总页数到 Store
    func syncPageState() {
      guard let pdfView, let doc = pdfView.document else { return }
      parent.pdfStore.pageCount = doc.pageCount
      if let page = pdfView.currentPage {
        parent.pdfStore.currentPage = doc.index(for: page) + 1
      }
    }

    @objc func pageChanged(_ note: Notification) {
      syncPageState()
    }

    @objc func scaleChanged(_ note: Notification) {
      guard let pdfView, !isPinching else { return }
      parent.pdfStore.scale = pdfView.scaleFactor
    }

    /// 捏合缩放（响应链 magnify 通道）：
    /// 手势期间只做 GPU 图层缩放（流畅、无重排）；结束时一次性应用真实缩放并重排。
    func handleMagnify(phase: NSEvent.Phase, magnification: CGFloat) {
      guard let pdfView else { return }
      switch phase {
      case .began:
        isPinching = true
        pinchStartScale = pdfView.scaleFactor
        pinchTotalMagnification = 1
        pdfView.wantsLayer = true
        // 记录缩放锚点：视图中心对应的文档点
        anchorPage = pdfView.currentPage
        anchorDocPoint = anchorPage.map {
          pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: $0)
        }
        // 手势期间临时收起文本选区：PDFView 会围绕选区反复滚动（乱跳根因）
        savedSelection = pdfView.currentSelection
        if savedSelection != nil {
          pdfView.setCurrentSelection(nil, animate: false)
        }
      case .changed:
        guard isPinching else { return }
        pinchTotalMagnification *= (1 + magnification)
        let target = PDFReaderStore.clamped(pinchStartScale * pinchTotalMagnification)
        let ratio = target / pinchStartScale
        // 围绕视图中心的图层变换（平移-缩放-平移），不会从角落扩张
        let bounds = pdfView.bounds
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        transform = CATransform3DScale(transform, ratio, ratio, 1)
        transform = CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
        pdfView.layer?.transform = transform
      case .ended, .cancelled:
        guard isPinching else { return }
        isPinching = false
        let target = PDFReaderStore.clamped(pinchStartScale * pinchTotalMagnification)
        // 同一 runloop 内先清图层变换再应用真实缩放，一次性重排，避免双重缩放帧
        pdfView.layer?.transform = CATransform3DIdentity
        if pdfView.autoScales { pdfView.autoScales = false }
        pdfView.scaleFactor = target
        // 重新居中到锚点：目标点置于视图顶部 = 锚点 - 半视口（文档坐标，y 向上）
        if let page = anchorPage, let anchor = anchorDocPoint {
          let halfWidth = pdfView.bounds.width / 2 / target
          let halfHeight = pdfView.bounds.height / 2 / target
          pdfView.go(to: PDFDestination(
            page: page,
            at: CGPoint(x: anchor.x - halfWidth, y: anchor.y + halfHeight)
          ))
        }
        anchorPage = nil
        anchorDocPoint = nil
        if let selection = savedSelection {
          pdfView.setCurrentSelection(selection, animate: false)
          savedSelection = nil
        }
        // 手势结束才回写 Store（卡顿根因：逐帧 @Published 触发 SwiftUI 重渲染）
        parent.pdfStore.scale = target
      default:
        break
      }
    }

    @objc func claimFocus(_ sender: Any) {
      parent.pdfStore.pdfView = pdfView
    }
  }
}

#Preview {
  PDFReaderView(url: URL(fileURLWithPath: "/tmp/demo.pdf"))
    .environmentObject(PDFReaderStore())
    .frame(width: 640, height: 480)
}
