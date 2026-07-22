import os
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

  /// Esc 回调（FR-3.4）：查找栏开启时退出查找，返回 true 表示已消费。
  /// keyDown 与 cancelOperation 双通道覆盖（PDFView 内部视图的键盘处理路径不一）
  var onEscape: (() -> Bool)?

  /// 焦点认领回调（分栏双 PDF）：mouseDown 即认领——划词拖拽位移超出点击手势
  /// 容差不触发识别，若只靠点击手势，「选中 → 浮动工具条标注」全程不产生焦点认领
  var onFocusClaim: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, onEscape?() == true { return }  // 53 = Esc
    super.keyDown(with: event)
  }

  override func cancelOperation(_ sender: Any?) {
    if onEscape?() == true { return }
    super.cancelOperation(sender)
  }

  override func magnify(with event: NSEvent) {
    onMagnify?(event.phase, event.magnification)
  }

  override func mouseDown(with event: NSEvent) {
    // 任何直接按下先认领焦点（须在批注标记拦截与 PDFKit 处理之前）
    onFocusClaim?()
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
    applyReadingTheme(settings.pdfReadingTheme, to: pdfView)
    pdfView.onMagnify = { [weak coordinator = context.coordinator] phase, magnification in
      coordinator?.handleMagnify(phase: phase, magnification: magnification)
    }
    // Esc 退出查找（FR-3.4）：焦点在 PDF 上时也能退出，无需先聚焦查找框
    pdfView.onEscape = { [weak coordinator = context.coordinator] in
      coordinator?.handleEscape() ?? false
    }
    // mouseDown 层认领焦点（划词拖拽不触发下面的点击手势，见 onFocusClaim 注释）
    pdfView.onFocusClaim = { [weak coordinator = context.coordinator] in
      coordinator?.claimFocus()
    }

    // 点击认领焦点：分栏双 PDF 时，缩放/搜索作用于最近点击的视图（FR-1.4）。
    // delaysPrimaryMouseButtonEvents=false：不拦截鼠标事件，否则 PDFView 收不到
    // mouseDown，文本选区点击别处无法取消。
    // 子视图（浮动工具条/删除按钮）上的点击也会路由到此识别器，作为 mouseDown 之外的补充
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
    center.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.selectionChanged(_:)),
      name: .PDFViewSelectionChanged,
      object: pdfView
    )
    context.coordinator.pdfView = pdfView
    pdfStore.pdfView = pdfView
    // 划词浮动工具条（FR-4.1）与标注写回关联（FR-4.6）
    context.coordinator.toolbarController = AnnotationToolbarController(
      pdfView: pdfView,
      store: annotationStore
    )
    // 异步解析文档（NFR-1：大 PDF 主线程同步解析整窗卡顿，237 页实测 ~1s）
    context.coordinator.loadDocumentAsync(url: url)
    return pdfView
  }

  func updateNSView(_ pdfView: PDFView, context: Context) {
    if context.coordinator.requestedURL != url {
      // 切换文档前先落盘挂起的标注写回（Bug C1）：store 对 document 是弱引用，
      // 下面清空 pdfView.document 后旧文档强引用归零，flush 会静默失败，
      // 500ms 防抖窗口内的标注改动将无提示丢失
      annotationStore.flushPendingWrites()
      // 切换文档：清空旧文档并异步解析新文档（同 makeNSView 的异步通道）
      pdfView.document = nil
      context.coordinator.loadDocumentAsync(url: url)
      return
    }
    // 既有视图被重新激活：消费待跳转页（回链跳到已打开的 PDF，FR-5.3）
    context.coordinator.jumpToPendingPageIfAny()
    // FR-7.2：默认视图模式设置即时生效
    if pdfView.displayMode != settings.pdfViewMode.pdfDisplayMode {
      pdfView.displayMode = settings.pdfViewMode.pdfDisplayMode
    }
    // FR-3.6：阅读主题即时生效
    applyReadingTheme(settings.pdfReadingTheme, to: pdfView)
    // 外部驱动的目标缩放（按钮/快捷键）；手动缩放时脱离自适应
    if abs(pdfView.scaleFactor - pdfStore.scale) > 0.001 {
      pdfView.autoScales = false
      pdfView.scaleFactor = PDFReaderStore.clamped(pdfStore.scale)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  /// 阅读主题（FR-3.6）：白天原色；夜间反色 + 色相调整 180°
  ///（Dark Reader 方案：亮度反转、色相保持，图片观感接近正常——PDFKit 无内容流级
  /// 反色能力，这是其上最贴近「智能反色、图片不反色」的可行路径。
  /// 注意：新版 macOS 已移除 CIHueRotate（返回 nil，曾导致滤镜静默失效），
  /// 现用 CIHueAdjust 等价替代；羊皮纸档经用户决策移除）
  private func applyReadingTheme(_ theme: SettingsStore.PDFReadingTheme, to pdfView: PDFView) {
    pdfView.wantsLayer = true
    switch theme {
    case .day:
      pdfView.layer?.filters = nil
      pdfView.layer?.backgroundColor = nil
    case .night:
      // 反色 + 色相调整 180°（CIHueRotate 在新系统被移除，CIHueAdjust 等价）
      let invert = CIFilter(name: "CIColorInvert")
      let hueAdjust = CIFilter(name: "CIHueAdjust")
      hueAdjust?.setValue(Double.pi, forKey: "inputAngle")
      pdfView.layer?.filters = [invert, hueAdjust].compactMap { $0 }
      pdfView.layer?.backgroundColor = NSColor.black.cgColor
    }
  }

  static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(coordinator)
    coordinator.flushPositionSave()
    // 关窗/关标签前同样落盘挂起的标注写回（Bug C1）：此处 document 仍在，
    // 不 flush 则防抖窗口内的改动随视图拆除静默丢失
    coordinator.parent.annotationStore.flushPendingWrites()
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
    /// 已请求加载的文档 URL（加载途中重复 updateNSView 不重复解析）
    private(set) var requestedURL: URL?
    /// 文档解析代际号：快速连续切换时丢弃过期结果
    private var loadToken = 0
    /// 是否有解析在途
    private var inFlight = false
    /// 解析中的加载指示
    private var spinner: NSProgressIndicator?

    init(_ parent: PDFReaderView) {
      self.parent = parent
    }

    /// 异步解析 PDF 文档（NFR-1）：后台线程构造 PDFDocument，完成后回主线程挂载并做
    /// 标注关联/位置恢复/待跳转页消费；大文档主线程同步解析会整窗卡顿。按代际号防串档。
    func loadDocumentAsync(url: URL) {
      if inFlight, requestedURL == url { return }
      requestedURL = url
      loadToken += 1
      let token = loadToken
      inFlight = true
      showSpinner(true)
      Task.detached(priority: .userInitiated) { [weak self] in
        let document = PDFDocument(url: url)
        await MainActor.run { [weak self] in
          guard let self, token == self.loadToken, let pdfView = self.pdfView else { return }
          self.inFlight = false
          self.showSpinner(false)
          guard let document else {
            Logger.pdf.error("PDF 解析失败: \(url.path, privacy: .public)")
            return
          }
          pdfView.document = document
          pdfView.autoScales = true
          // 分栏双 PDF：仅本 pane 当前持有焦点时才关联标注 Store——否则后加载完成的
          // 视图会覆盖先加载视图的关联，把 A 窗标注写进 B 文档（焦点切换由 claimFocus 补关联）
          if self.parent.pdfStore.pdfView === pdfView {
            self.parent.annotationStore.attach(document: document, url: url)
          }
          self.syncPageState()
          // 阅读位置记忆（FR-3.5）；全文搜索/回链跳转（FR-6.2/5.3）优先于位置恢复
          self.restorePosition(url: url)
          self.jumpToPendingPageIfAny()
        }
      }
    }

    /// 解析中的旋转指示（完成或失败后移除）
    private func showSpinner(_ show: Bool) {
      if show {
        guard spinner == nil, let pdfView else { return }
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .large
        indicator.translatesAutoresizingMaskIntoConstraints = false
        pdfView.addSubview(indicator)
        NSLayoutConstraint.activate([
          indicator.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
          indicator.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
        ])
        indicator.startAnimation(nil)
        spinner = indicator
      } else {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
      }
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

    /// 选区变化（FR-5.2 菜单启用条件）
    @objc func selectionChanged(_ note: Notification) {
      guard let pdfView else { return }
      let has = pdfView.currentSelection != nil
      if parent.pdfStore.hasSelection != has {
        parent.pdfStore.hasSelection = has
      }
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
      claimFocus()
    }

    /// 认领焦点（FR-1.4 分栏仲裁：缩放/搜索/标注作用于最近交互的视图）。
    /// 标注 Store 跟随焦点指向本窗文档：attach 替换目标前会先落盘旧文档的挂起改动；
    /// 划词/工具条/批注等交互总是先产生焦点，写回目的地因此始终是用户正在操作的文档
    func claimFocus() {
      parent.pdfStore.pdfView = pdfView
      if let pdfView, let document = pdfView.document {
        parent.annotationStore.attach(document: document, url: parent.url)
      }
    }

    /// Esc 退出查找（FR-3.4）：查找栏开启时关闭并消费；焦点在 PDF 上（非查找框）也生效
    func handleEscape() -> Bool {
      guard parent.pdfStore.isFindBarVisible else { return false }
      parent.pdfStore.closeFindBar()
      return true
    }

    /// 消费指向本窗文档的待跳转页（FR-6.2 搜索 / FR-5.3 回链）；pendingFlash 时闪烁页面提示。
    /// 文档未就绪（异步解析中）不消费，待加载完成后统一处理
    func jumpToPendingPageIfAny() {
      guard let pdfView, let document = pdfView.document,
        let (page, flash) = parent.pdfStore.consumePendingJump(for: parent.url)
      else { return }
      // 直接导航本视图：不经 store.goTo——其 pdfView 是分栏焦点视图，可能指向另一窗格
      guard page >= 1, page <= document.pageCount, let target = document.page(at: page - 1)
      else { return }
      pdfView.go(to: target)
      if flash {
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
