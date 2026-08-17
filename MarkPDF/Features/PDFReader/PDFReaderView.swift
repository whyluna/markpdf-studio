import os
import PDFKit
import SwiftUI

/// 支持捏合缩放的 PDFView（FR-3.2）。
/// 捏合走 PDFKit 原生通道（不再自绘管线）：自绘方案（图层缩放 + 结束落定）两条事件
/// 通道都被 PDFKit 内部管线间歇吞掉（响应链/手势识别器各自实测失效过），且 PDFKit
/// 重排会丢弃残留图层变换（视觉弹回）。原生 pinch 直接改 scaleFactor，经
/// PDFViewScaleChanged 通知同步 Store，状态栏比例实时跟随，边界由 min/maxScaleFactor 钳制
final class ZoomablePDFView: PDFView {
  /// 手型光标区域（视图坐标）：命中时显示手型并屏蔽 PDFKit 的文本 I 形光标
  /// （用于浮动按钮——PDFView 会按文字命中把光标抢设为 I 形，必须在 PDFKit 管线内拦截）
  var handCursorRects: [CGRect] = []

  /// 批注图标 mouseDown 拦截（FR-4.3）：返回 true 表示命中批注标记并已处理，
  /// 事件不传给 PDFKit——否则 PDFView 会原生打开 /Text 的 Popup 弹窗（深蓝框），
  /// 且手势识别器路径时灵时不灵（PDFView 会先吃掉图标上的点击）
  var onCommentMarkerMouseDown: ((NSPoint) -> Bool)?

  /// 既有标注的点选（FR-4.1 点选删除）：同走 mouseDown 通道且不吞事件——
  /// 挂在 NSClickGestureRecognizer 上时会被 PDFKit 自己的手势吃掉（新系统实测点不中），
  /// 与批注图标同一结论
  var onAnnotationMouseDown: ((NSPoint) -> Void)?

  /// 手指光标查询（FR-4.3）：命中批注标记时返回 true。
  /// PDFView 在 /Text 图标上原生显示"抓抓手"，必须在 PDFKit 光标管线内改成手指
  var onPointingHandQuery: ((NSPoint) -> Bool)?

  /// Esc 回调（FR-3.4）：查找栏开启时退出查找，返回 true 表示已消费。
  /// keyDown 与 cancelOperation 双通道覆盖（PDFView 内部视图的键盘处理路径不一）
  var onEscape: (() -> Bool)?

  /// 焦点认领回调（分栏双 PDF）：mouseDown 即认领——划词拖拽位移超出点击手势
  /// 容差不触发识别，若只靠点击手势，「选中 → 浮动工具条标注」全程不产生焦点认领
  var onFocusClaim: (() -> Void)?

  /// 最近一次 mouseDown 位置（视图坐标）：划词选区分栏裁剪（SelectionColumnTrimmer）的拖拽起点
  private(set) var lastMouseDownPoint: NSPoint?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    disableDocumentAnalysis()
    setupViewportClipping()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    disableDocumentAnalysis()
    setupViewportClipping()
  }

  /// 裁剪到视口：批注卡片/连线层等覆盖子视图跟随内容滚动，位置可能落在
  /// 可见区之外（如内容滚出上缘）；PDFView 默认不裁剪子视图，溢出部分
  /// 会画到上方标签栏（实测上滚后遮挡标签页）。开子视图裁剪统一兜底
  private func setupViewportClipping() {
    clipsToBounds = true
  }

  /// macOS 26 文档分析会把对齐排版的题行（题干+ABCD 选项）识别成表单候选，
  /// 交互时触发"智能选区"：点击弹出带手柄的蓝框并劫持原生文本选择（A 类文本蓝框根因，
  /// 事件在 PDFKit 内部子视图层就被消费，mouseDown 重写收不到）。关闭后 A/B 文本统一走
  /// 原生选择管线。私有 API：键不存在时静默跳过，系统更新后自动退回现状
  private func disableDocumentAnalysis() {
    guard responds(to: NSSelectorFromString("setDocumentAnalysisEnabled:")) else { return }
    setValue(false, forKey: "documentAnalysisEnabled")
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, onEscape?() == true { return }  // 53 = Esc
    super.keyDown(with: event)
  }

  override func cancelOperation(_ sender: Any?) {
    if onEscape?() == true { return }
    super.cancelOperation(sender)
  }

  override func mouseDown(with event: NSEvent) {
    // 任何直接按下先认领焦点（须在批注标记拦截与 PDFKit 处理之前）
    onFocusClaim?()
    let point = convert(event.locationInWindow, from: nil)
    lastMouseDownPoint = point
    if let handler = onCommentMarkerMouseDown, handler(point) {
      return
    }
    // 既有标注点选（虚线框 + 删除按钮）：不吞事件，划词/取消选区照常
    onAnnotationMouseDown?(point)
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
    // 超链接（目录/交叉引用）：标注设只读后 PDFKit 不再给小手，自己接管
    if link(at: point) != nil {
      NSCursor.pointingHand.set()
      return
    }
    super.cursorUpdate(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    // 点击（非拖拽划词）落在超链接上 → 自己执行跳转：
    // 标注只读后 PDFKit 不再处理 Link 交互（只读是为了压掉它的原生选中蓝框）
    if let start = lastMouseDownPoint, hypot(point.x - start.x, point.y - start.y) < 3,
      let annotation = link(at: point)
    {
      super.mouseUp(with: event)
      follow(link: annotation)
      return
    }
    super.mouseUp(with: event)
  }

  /// 命中该点的超链接标注（Link 子类型）
  private func link(at point: NSPoint) -> PDFAnnotation? {
    guard let page = page(for: point, nearest: false) else { return nil }
    let pagePoint = convert(point, to: page)
    guard let annotation = page.annotation(at: pagePoint),
      let raw = annotation.type
    else { return nil }
    let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    return name == "Link" ? annotation : nil
  }

  /// 执行超链接：页内目标跳转 / 外部 URL / 命名动作（首末页、翻页）
  private func follow(link annotation: PDFAnnotation) {
    if let destination = annotation.destination {
      go(to: destination)
      return
    }
    switch annotation.action {
    case let action as PDFActionGoTo:
      go(to: action.destination)
    case let action as PDFActionURL:
      if let url = action.url {
        NSWorkspace.shared.open(url)
      }
    case let action as PDFActionNamed:
      switch action.name {
      case .nextPage: goToNextPage(nil)
      case .previousPage: goToPreviousPage(nil)
      case .firstPage: goToFirstPage(nil)
      case .lastPage: goToLastPage(nil)
      case .goBack: goBack(nil)
      case .goForward: goForward(nil)
      default: break
      }
    default:
      break
    }
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
  @EnvironmentObject private var aiSettings: AISettingsStore
  @EnvironmentObject private var aiKeys: AIKeyStore
  /// 全局外观联动：深色 → 夜间反色（NSApp.appearance 覆盖与系统切换都会实时传导）
  @Environment(\.colorScheme) private var colorScheme

  /// 夜间档判定（纯函数供单测）
  static func isNightTheme(_ colorScheme: ColorScheme) -> Bool {
    colorScheme == .dark
  }

  func makeNSView(context: Context) -> PDFView {
    let pdfView = ZoomablePDFView()
    // FR-7.2：默认视图模式设置
    pdfView.displayMode = settings.pdfViewMode.pdfDisplayMode
    pdfView.displayDirection = .vertical
    pdfView.autoScales = true
    // 捏合缩放走 PDFKit 原生通道，边界与按钮缩放同域（50%–400%）
    pdfView.minScaleFactor = PDFReaderStore.minScale
    pdfView.maxScaleFactor = PDFReaderStore.maxScale
    applyReadingTheme(Self.isNightTheme(colorScheme) ? .night : .day, to: pdfView)
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
    // 捏合缩放（FR-3.2）窗口级接管：事件进 App 的监控通道实测永不丢（PDFKit 内部
    //  pinch 在文档重挂载后只预览不落 scaleFactor——视觉变了又弹回、状态栏不跟；
    //  响应链 magnify(with:) 也会被其间歇吞掉），落点在本视图内即就地缩放并吞掉事件
    context.coordinator.magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak coordinator = context.coordinator] event in
      coordinator?.handleWindowMagnify(event)
    }
    // 划词浮动工具条（FR-4.1 + FR-AI.1 划词翻译）与标注写回关联（FR-4.6）
    context.coordinator.toolbarController = AnnotationToolbarController(
      pdfView: pdfView,
      store: annotationStore,
      aiSettings: aiSettings,
      aiKeys: aiKeys
    )
    // 异步解析文档（NFR-1：大 PDF 主线程同步解析整窗卡顿，237 页实测 ~1s）
    context.coordinator.loadDocumentAsync(url: url)
    return pdfView
  }

  func updateNSView(_ pdfView: PDFView, context: Context) {
    // 视图被同类标签复用（切标签不重建，同类不同文档共用同一 PDFView）：
    // parent 必须每轮跟随——否则 coordinator 里的 url 停留在首个文档，
    // 位置/缩放存档全部写到第一个文件名下（实测「答案」的存档全记到「讲义」）
    context.coordinator.parent = self
    if context.coordinator.requestedURL != url {
      // 切换文档前先落盘挂起的标注写回（Bug C1）：store 对 document 是弱引用，
      // 下面清空 pdfView.document 后旧文档强引用归零，flush 会静默失败，
      // 500ms 防抖窗口内的标注改动将无提示丢失
      annotationStore.flushPendingWrites()
      // 同理落盘旧文档的阅读位置：防抖挂起的存档若留到新文档挂载后才落定，
      // 会用新文档的第 1 页覆盖旧文件的好存档（实测切标签丢位置的根因）
      context.coordinator.flushPositionSave()
      // Bug 修复 1/2：查找状态整体复位（findMatches 是旧文档的 PDFSelection，
      // ⌘G/回车会作用于新文档，行为未定义）；缩放归位 100%，避免旧倍率在加载窗口期
      // 误关 autoScales（存档缩放由加载完成后的 restorePosition 恢复，不受影响）
      pdfStore.resetForDocumentSwitch()
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
    // FR-3.6：阅读主题即时生效（深浅外观切换时 updateNSView 会被再次触发）
    applyReadingTheme(Self.isNightTheme(colorScheme) ? .night : .day, to: pdfView)
    // 外部驱动的目标缩放（按钮/快捷键）；手动缩放时脱离自适应。
    // 加载窗口期不同步（Bug 修复 2）：document 未挂载时 scaleFactor 仍是初值 1.0，
    // 若此时按 store 残留倍率同步会误关 autoScales，新文档失去自适应宽度
    if Self.shouldSyncScale(
      hasDocument: pdfView.document != nil,
      scaleFactor: pdfView.scaleFactor,
      targetScale: pdfStore.scale
    ) {
      pdfView.autoScales = false
      pdfView.scaleFactor = PDFReaderStore.clamped(pdfStore.scale)
    }
  }

  /// 缩放同步判定（Bug 修复 2）：加载窗口期（document 未挂载）一律不同步；
  /// 文档就绪后按目标倍率与当前值的差异决定（容差 0.001 防抖）
  static func shouldSyncScale(hasDocument: Bool, scaleFactor: CGFloat, targetScale: CGFloat) -> Bool {
    hasDocument && abs(scaleFactor - targetScale) > 0.001
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
    // local monitor 由系统事件通道持有，与 coordinator 生命周期无关——
    // 不摘除则每次开 PDF 标签泄漏一个全局监控器（随标签开闭线性增长）
    if let monitor = coordinator.magnifyMonitor {
      NSEvent.removeMonitor(monitor)
      coordinator.magnifyMonitor = nil
    }
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
    /// 已请求加载的文档 URL（加载途中重复 updateNSView 不重复解析）
    private(set) var requestedURL: URL?
    /// 文档解析代际号：快速连续切换时丢弃过期结果
    private var loadToken = 0
    /// 是否有解析在途
    private var inFlight = false
    /// 解析中的加载指示
    private var spinner: NSProgressIndicator?
    /// 解析失败占位视图（Bug 修复 3：重试入口）
    private var failureHosting: NSHostingView<PDFLoadFailureView>?
    /// 是否已挂上滚动实时监听（clip view 跨文档复用，避免重复注册）
    private var isObservingScroll = false
    /// 滚动实时监听记录的当前页（0 起；-1 = 未知）
    private var lastLivePageIndex = -1
    /// 捏合落点取证监视器（随 coordinator 释放）
    var magnifyMonitor: Any?

    init(_ parent: PDFReaderView) {
      self.parent = parent
    }

    deinit {
      // 兜底：dismantle 已摘除；万一视图未经 dismantle 释放也绝不驻留系统事件通道
      if let monitor = magnifyMonitor {
        NSEvent.removeMonitor(monitor)
      }
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
      // 新一次加载尝试：清掉上次的失败占位与错误（Bug 修复 3）
      showLoadFailure(false)
      parent.pdfStore.lastError = nil
      Task.detached(priority: .userInitiated) { [weak self] in
        let document = PDFDocument(url: url)
        await MainActor.run { [weak self] in
          guard let self, token == self.loadToken, let pdfView = self.pdfView else { return }
          self.inFlight = false
          self.showSpinner(false)
          guard let document else {
            Logger.pdf.error("PDF 解析失败: \(url.path, privacy: .public)")
            // Bug 修复 3：解析失败须用户可感知（NFR-5）——记录错误并展示带重试的占位，
            // 否则 requestedURL 已置为当前 url，updateNSView 不会再触发加载，用户面对永久空白
            self.parent.pdfStore.reportLoadFailure(for: url)
            self.showLoadFailure(true)
            return
          }
          pdfView.document = document
          pdfView.autoScales = true
          self.lastLivePageIndex = -1
          self.startScrollObservationIfNeeded()
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

    /// 解析失败占位（Bug 修复 3）：说明 + 重试按钮；重试/切换文档/加载成功时移除
    private func showLoadFailure(_ show: Bool) {
      if show {
        guard failureHosting == nil, let pdfView else { return }
        let hosting = NSHostingView(rootView: PDFLoadFailureView(
          message: parent.pdfStore.lastError ?? String(localized: "无法打开 PDF"),
          onRetry: { [weak self] in self?.retryLoad() }
        ))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        pdfView.addSubview(hosting)
        NSLayoutConstraint.activate([
          hosting.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
          hosting.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
        ])
        failureHosting = hosting
      } else {
        failureHosting?.removeFromSuperview()
        failureHosting = nil
      }
    }

    /// 解析失败后的重试（Bug 修复 3）：requestedURL 未变，updateNSView 不会自发重试，
    /// 必须显式重走异步解析通道（loadDocumentAsync 起始处会清失败状态）
    func retryLoad() {
      guard let url = requestedURL else { return }
      loadDocumentAsync(url: url)
    }

    /// 同步页码/总页数到 Store（页码用视口中心页，与滚动实时跟页同一口径）
    func syncPageState() {
      guard let pdfView, let doc = pdfView.document else { return }
      parent.pdfStore.pageCount = doc.pageCount
      if let page = visibleCenterPage() ?? pdfView.currentPage {
        parent.pdfStore.currentPage = doc.index(for: page) + 1
      }
    }

    /// 视口中心对应的页（滚动中实时准确；PDFKit 的 currentPage 在连续滚动中不更新）
    private func visibleCenterPage() -> PDFPage? {
      guard let pdfView else { return nil }
      return pdfView.page(
        for: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), nearest: true)
    }

    @objc func pageChanged(_ note: Notification) {
      // @Published 写入推迟出显示周期（拖动右栏时窗口在持续 display cycle，
      // 直写触发托管视图中途失效约束 = AppKit trap 闪退）
      DispatchQueue.main.async { [weak self] in
        self?.syncPageState()
        self?.schedulePositionSave()
      }
    }

    // MARK: - 滚动实时跟页（缩略图/页码同步）

    /// PDFKit 限制（实测日志确认）：连续滚动中 `currentPage` 不更新、
    /// `PDFViewPageChanged` 要等滚动停稳约 1s 才发——原生缩略图/页码观感是「停下才跳」。
    /// 修法：监听 PDFView 内部 clip view 的 bounds 实时变化，用视口中心页实算页码
    /// 直写 Store，驱动自绘缩略图列表（PDFThumbnailListView）与工具栏页码实时跟随
    private func startScrollObservationIfNeeded() {
      guard !isObservingScroll, let pdfView,
        let clipView = pdfView.documentView?.enclosingScrollView?.contentView
      else { return }
      isObservingScroll = true
      clipView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(liveScrolled(_:)),
        name: NSView.boundsDidChangeNotification,
        object: clipView
      )
    }

    @objc private func liveScrolled(_ note: Notification) {
      guard let pdfView, let doc = pdfView.document, let page = visibleCenterPage() else { return }
      let index = doc.index(for: page)
      guard index != lastLivePageIndex else { return }
      lastLivePageIndex = index
      // @Published 写入推迟出显示周期：拖动右栏（检查器）时窗口在持续 display cycle，
      // 这里直写会让 SwiftUI 托管视图在布局中途失效窗口约束——AppKit 直接 trap（实测闪退）
      DispatchQueue.main.async { [weak self, weak pdfView] in
        guard let self, let pdfView, self.parent.pdfStore.pdfView === pdfView else { return }
        // 分栏双 PDF：只有焦点视图才回写共享 Store，否则两窗滚动互相覆盖页码
        self.parent.pdfStore.currentPage = index + 1
      }
    }

    @objc func scaleChanged(_ note: Notification) {
      guard let pdfView else { return }
      // 拆卸/清文档（document=nil）时 scaleFactor 回落 1.0：不回写 Store，
      // 否则切标签把好端端的缩放存档冲成 100%
      guard pdfView.document != nil else { return }
      let scale = pdfView.scaleFactor
      DispatchQueue.main.async { [weak self] in
        self?.parent.pdfStore.scale = scale
        self?.schedulePositionSave()
      }
    }

    /// 选区变化（FR-5.2 菜单启用条件）
    @objc func selectionChanged(_ note: Notification) {
      guard let pdfView else { return }
      let has = pdfView.currentSelection != nil
      DispatchQueue.main.async { [weak self] in
        guard let self, self.parent.pdfStore.hasSelection != has else { return }
        self.parent.pdfStore.hasSelection = has
      }
    }

    // MARK: - 阅读位置记忆（FR-3.5）

    /// 恢复上次阅读位置（页码 + 缩放）；无存档则保持自适应宽度
    func restorePosition(url: URL) {
      guard let pdfView, let doc = pdfView.document else { return }
      guard let saved = parent.positionStore.position(for: url) else { return }
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

    /// 防抖记录当前页码与缩放。页码取视口中心页（PDFKit currentPage 滚动中滞后、
    /// 拆卸/离屏时为 nil——nil 会落成页1 把好存档覆盖掉，实测切标签即丢位置）；
    /// 取值推迟到防抖落盘那一刻，且视图不在窗口上时整次跳过（teardown 不误存）
    private func schedulePositionSave() {
      guard let pdfView, pdfView.document != nil else { return }
      let url = parent.url
      positionDebouncer.schedule { [weak self, weak pdfView] in
        guard let self, let pdfView, pdfView.window != nil,
          let doc = pdfView.document, let center = self.visibleCenterPage()
        else { return }
        // 防抖窗口内已切走（视图被同类标签复用）：过期存档不落地
        guard self.requestedURL == url else { return }
        let page = doc.index(for: center) + 1
        let scale = Double(pdfView.scaleFactor)
        self.parent.positionStore.save(.init(page: page, scale: scale), for: url)
      }
    }

    /// 视图拆除前落盘挂起的位置记录
    func flushPositionSave() {
      positionDebouncer.fire()
    }

    /// 捏合缩放（窗口级接管，FR-3.2）：落点在本视图内 → 就地改 scaleFactor 并吞掉事件
    ///（PDFKit 的瞬态预览不再重复执行）。逐事件直改而非图层变换：PDFView 图层变换
    /// 会只显示一小块区域（实测严重缺陷），宁可每帧重排也要正确
    /// scaleFactor 变化触发 PDFViewScaleChanged → Store 同步与位置存档走既有通道
    func handleWindowMagnify(_ event: NSEvent) -> NSEvent? {
      guard let pdfView, pdfView.window === event.window else { return event }
      let point = pdfView.convert(event.locationInWindow, from: nil)
      guard pdfView.bounds.contains(point) else { return event }
      // 捏合即脱离自适应宽度（缩放才不被下一次布局打回）
      if pdfView.autoScales { pdfView.autoScales = false }
      pdfView.scaleFactor = PDFReaderStore.clamped(pdfView.scaleFactor * (1 + event.magnification))
      return nil
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
        // 目的地取文档自带 URL：切标签时 parent.url 先更新、document 要等异步加载完才换，
        // 这个空窗里用 parent.url 会把「旧文档 + 新路径」配成一对（Store 侧也有兜底纠正）
        parent.annotationStore.attach(document: document, url: document.documentURL ?? parent.url)
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

/// 解析失败占位视图（Bug 修复 3）：图标 + 说明 + 重试按钮，
/// 文字风格对齐既有空状态（"暂无标注"等：.callout + secondary）
private struct PDFLoadFailureView: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "doc.questionmark")
        .font(.system(size: 28))
        .foregroundStyle(.secondary)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("重试", action: onRetry)
    }
    .padding(16)
  }
}

#Preview {
  PDFReaderView(url: URL(fileURLWithPath: "/tmp/demo.pdf"))
    .environmentObject(PDFReaderStore())
    .environmentObject(PDFAnnotationStore())
    .environmentObject(PDFReadingPositionStore())
    .environmentObject(SettingsStore())
    .environmentObject(AISettingsStore())
    .environmentObject(AIKeyStore())
    .frame(width: 640, height: 480)
}
