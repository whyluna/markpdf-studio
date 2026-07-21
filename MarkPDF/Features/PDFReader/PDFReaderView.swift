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

  /// 批注图标 mouseDown 拦截（FR-4.3）：返回 true 表示命中批注标记并已处理，
  /// 事件不传给 PDFKit——否则 PDFView 会原生打开 /Text 的 Popup 弹窗（深蓝框），
  /// 且手势识别器路径时灵时不灵（PDFView 会先吃掉图标上的点击）
  var onCommentMarkerMouseDown: ((NSPoint) -> Bool)?

  /// 手指光标查询（FR-4.3）：命中批注标记时返回 true。
  /// PDFView 在 /Text 图标上原生显示"抓抓手"，必须在 PDFKit 光标管线内改成手指
  var onPointingHandQuery: ((NSPoint) -> Bool)?

  override func magnify(with event: NSEvent) {
    onMagnify?(event.phase, event.magnification)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let handler = onCommentMarkerMouseDown, handler(point) {
      return
    }
    super.mouseDown(with: event)
  }

  override func cursorUpdate(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if onPointingHandQuery?(point) == true {
      NSCursor.pointingHand.set()
      return
    }
    if handCursorRects.contains(where: { $0.contains(point) }) {
      NSCursor.pointingHand.set()
      return
    }
    super.cursorUpdate(with: event)
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if onPointingHandQuery?(point) == true {
      NSCursor.pointingHand.set()
      return
    }
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
  @EnvironmentObject private var positionStore: PDFReadingPositionStore
  @EnvironmentObject private var settings: SettingsStore

  func makeNSView(context: Context) -> PDFView {
    let pdfView = ZoomablePDFView()
    // FR-7.2：默认视图模式设置
    pdfView.displayMode = settings.pdfViewMode.pdfDisplayMode
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
    // 阅读位置记忆（FR-3.5）：恢复上次页码与缩放
    context.coordinator.restorePosition(url: url)
    // 全文搜索命中/回链跳转（FR-6.2/FR-5.3）：优先于位置恢复
    context.coordinator.jumpToPendingPageIfAny()
    return pdfView
  }

  func updateNSView(_ pdfView: PDFView, context: Context) {
    if pdfView.document?.documentURL != url {
      pdfView.document = PDFDocument(url: url)
      // 新文档默认自适应宽度；有阅读位置存档则恢复（FR-3.5）
      pdfView.autoScales = true
      context.coordinator.syncPageState()
      if let document = pdfView.document {
        annotationStore.attach(document: document, url: url)
      }
      context.coordinator.restorePosition(url: url)
      context.coordinator.jumpToPendingPageIfAny()
      return
    }
    // 既有视图被重新激活：消费待跳转页（回链跳到已打开的 PDF，FR-5.3）
    context.coordinator.jumpToPendingPageIfAny()
    // FR-7.2：默认视图模式设置即时生效
    if pdfView.displayMode != settings.pdfViewMode.pdfDisplayMode {
      pdfView.displayMode = settings.pdfViewMode.pdfDisplayMode
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
    coordinator.flushPositionSave()
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: PDFReaderView
    weak var pdfView: PDFView?
    /// 划词浮动工具条控制器（FR-4.1）
    var toolbarController: AnnotationToolbarController?
    /// 阅读位置落盘防抖（FR-3.5：翻页/缩放高频，合并写）
    private let positionDebouncer = Debouncer(interval: 0.5)
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
      schedulePositionSave()
    }

    @objc func scaleChanged(_ note: Notification) {
      guard let pdfView, !isPinching else { return }
      parent.pdfStore.scale = pdfView.scaleFactor
      schedulePositionSave()
    }

    // MARK: - 阅读位置记忆（FR-3.5）

    /// 恢复上次阅读位置（页码 + 缩放）；无存档则保持自适应宽度
    func restorePosition(url: URL) {
      guard let pdfView, let doc = pdfView.document,
        let saved = parent.positionStore.position(for: url)
      else { return }
      let scale = PDFReaderStore.clamped(CGFloat(saved.scale))
      pdfView.autoScales = false
      pdfView.scaleFactor = scale
      let pageIndex = min(max(saved.page - 1, 0), doc.pageCount - 1)
      if let page = doc.page(at: pageIndex) {
        pdfView.go(to: page)
      }
      parent.pdfStore.scale = scale
      syncPageState()
    }

    /// 防抖记录当前页码与缩放
    private func schedulePositionSave() {
      guard let pdfView, let doc = pdfView.document else { return }
      let page = pdfView.currentPage.map { doc.index(for: $0) + 1 } ?? 1
      let scale = Double(pdfView.scaleFactor)
      let url = parent.url
      positionDebouncer.schedule { [weak self] in
        self?.parent.positionStore.save(.init(page: page, scale: scale), for: url)
      }
    }

    /// 视图拆除前落盘挂起的位置记录
    func flushPositionSave() {
      positionDebouncer.fire()
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

    /// 消费待跳转页（FR-6.2 搜索 / FR-5.3 回链）；pendingFlash 时闪烁页面提示
    func jumpToPendingPageIfAny() {
      guard let pdfView, let page = parent.pdfStore.pendingPage else { return }
      parent.pdfStore.pendingPage = nil
      let flash = parent.pdfStore.pendingFlash
      parent.pdfStore.pendingFlash = false
      parent.pdfStore.goTo(page: page)
      if flash, let target = pdfView.document?.page(at: page - 1) {
        // 等 PDFKit 完成跳转布局后再放覆盖层（位置才准）
        DispatchQueue.main.async {
          AnnotationFlasher.flashPage(target, in: pdfView)
        }
      }
    }
  }
}

#Preview {
  PDFReaderView(url: URL(fileURLWithPath: "/tmp/demo.pdf"))
    .environmentObject(PDFReaderStore())
    .environmentObject(PDFAnnotationStore())
    .environmentObject(PDFReadingPositionStore())
    .environmentObject(SettingsStore())
    .frame(width: 640, height: 480)
}
