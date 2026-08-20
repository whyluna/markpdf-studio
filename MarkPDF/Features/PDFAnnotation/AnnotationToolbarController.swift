import Combine
import os
import PDFKit
import SwiftUI

/// 划词浮动工具条控制器（FR-4.1 + FR-AI.1）：
/// 监听 PDFView 选区变化，鼠标松开后在选区上方弹出工具条；
/// 动作时把选区转为对应文本标注（逐行创建，精确贴合选中文字）。
/// 另支持点击既有标注 → 弹出删除按钮（点选即删）；
/// 划词翻译气泡挂在工具条正下方（自动触发可在设置关闭，工具条上有手动入口）。
@MainActor
final class AnnotationToolbarController: NSObject {
  private weak var pdfView: PDFView?
  /// 覆盖层宿主（与 pdfView 平级同帧）：夜间反色滤镜挂在 pdfView 图层上，
  /// 覆盖层挂其内会被连带反色（深色下卡片深底变白块）——一律挂宿主
  private weak var overlayHost: NSView?
  private let store: PDFAnnotationStore
  private let aiSettings: AISettingsStore
  private let translationStore: TranslationStore
  private var hostingView: NSHostingView<SelectionFloatingPanel>?
  private var mouseUpMonitor: Any?
  private var keyMonitor: Any?
  private var toolCancellable: AnyCancellable?
  private var translationCancellable: AnyCancellable?
  /// 交互源注册令牌（分栏双控制器互不覆盖；deinit 注销）
  private var interactionCheckID: UUID?

  /// 覆盖层挂载点：宿主缺席（异常装配）退回 pdfView，保证功能可用
  private var overlayParent: NSView? { overlayHost ?? pdfView }

  init(pdfView: PDFView, overlayHost: NSView, store: PDFAnnotationStore, aiSettings: AISettingsStore, aiKeys: AIKeyStore) {
    self.pdfView = pdfView
    self.overlayHost = overlayHost
    self.store = store
    self.aiSettings = aiSettings
    translationStore = TranslationStore(settings: aiSettings, service: AIService(keys: aiKeys))
    super.init()

    let panel = SelectionFloatingPanel(
      store: store,
      translationStore: translationStore,
      onApply: { [weak self] kind in self?.apply(kind: kind) },
      onTranslate: { [weak self] in self?.triggerTranslation() }
    )
    let hosting = NSHostingView(rootView: panel)
    hosting.isHidden = true
    overlayHost.addSubview(hosting)
    hostingView = hosting

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(selectionChanged(_:)),
      name: .PDFViewSelectionChanged,
      object: pdfView
    )
    // 鼠标松开才弹出（划词途中不打扰）；只响应本窗事件——
    // 别窗/侧栏的点击不应触发本视图的重排与面板复活
    mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      if event.window === self?.pdfView?.window {
        self?.revealIfSelection(at: event)
      }
      return event
    }
    // 点击既有标注 → 点选删除：走 pdfView 的 mouseDown 钩子而非手势识别器
    //（PDFKit 自己的手势会吃掉标注上的点击，新系统实测点不中；见 onAnnotationMouseDown）
    if let zoomable = pdfView as? ZoomablePDFView {
      zoomable.onAnnotationMouseDown = { [weak self] point in
        self?.handleAnnotationMouseDown(at: point)
      }
    }
    // 交互期间（批注编辑框 / 点选编辑条打开）暂缓落盘：重扫与 PDF 全量写回都在主线程，
    // 落在打字/点色那一瞬会卡住 UI；交互结束统一写（store.resumeDeferredWrites）。
    // 按实例注册（store 为窗口级单例，分栏双控制器互不覆盖）
    interactionCheckID = store.registerInteractionCheck { [weak self] in
      guard let self else { return false }
      return self.commentPopover != nil || self.deleteHosting?.isHidden == false
    }
    // Esc 退出激活的标注工具（FR-4.4）；不吞事件，查找栏等照常响应。
    // 只响应本窗按键——别窗按 Esc 不应退出本窗工具
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53, event.window === self?.pdfView?.window, self?.store.activeTool != nil {
        self?.store.activeTool = nil
      }
      return event
    }
    // 工具激活时收起浮动工具条（进入划词即标模式）
    toolCancellable = store.$activeTool.sink { [weak self] tool in
      if tool != nil {
        self?.hide()
      }
    }
    // 翻译气泡出现/消失改变面板高度 → 以当前选区重排（保持夹取在视图内）。
    // receive(on:) 与 @Published 的发射解耦：sink 在 willSet 同步上下文里直接驱动
    // AppKit 布局会干扰 SwiftUI 更新事务（UI 停在旧相位不刷新的嫌疑路径之一）
    translationCancellable = translationStore.$phase
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.relayoutPanel()
      }
    // 批注图标点击在 mouseDown 层拦截（FR-4.3）：PDFKit 收不到事件，
    // 原生 Popup 弹窗（深蓝框）不会触发；手势识别器路径时灵时不灵故弃用
    (pdfView as? ZoomablePDFView)?.onCommentMarkerMouseDown = { [weak self] point in
      self?.handleMarkerMouseDown(at: point) ?? false
    }
    // 批注图标上的光标：拦截 PDFView 原生的"抓抓手"，改为手指
    (pdfView as? ZoomablePDFView)?.onPointingHandQuery = { [weak self] point in
      self?.markerAt(viewPoint: point) != nil
    }
    setupCommentCards()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let mouseUpMonitor {
      NSEvent.removeMonitor(mouseUpMonitor)
    }
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
    if let interactionCheckID {
      // deinit 非隔离：注销派发到主线程执行（store 为 @MainActor）
      let store = store
      Task { @MainActor in
        store.unregisterInteractionCheck(interactionCheckID)
      }
    }
    toolCancellable?.cancel()
    translationCancellable?.cancel()
    commentCardCancellable?.cancel()
  }

  // MARK: - 弹出与隐藏

  @objc private func selectionChanged(_ note: Notification) {
    guard let pdfView else { return }
    if pdfView.currentSelection == nil {
      hide()
    }
  }

  private func revealIfSelection(at event: NSEvent) {
    guard let pdfView, pdfView.currentSelection != nil, !(pdfView.currentSelection?.pages.isEmpty ?? true) else {
      hide()
      return
    }
    // 双栏跨栏误选裁剪：拖拽起止在同一栏时仅保留该栏内容（右栏划词不再连带左栏）
    let dragEnd = pdfView.convert(event.locationInWindow, from: nil)
    SelectionColumnTrimmer.trimSelection(
      of: pdfView,
      dragStart: (pdfView as? ZoomablePDFView)?.lastMouseDownPoint,
      dragEnd: dragEnd
    )
    guard let selection = pdfView.currentSelection, !selection.pages.isEmpty else {
      hide()
      return
    }
    // 工具栏标注工具激活中（FR-4.4）：划词即标，不再弹出浮动工具条
    if let tool = store.activeTool {
      apply(kind: tool)
      return
    }
    // 记录松手点：定位算法的鼠标侧判据（面板放在离手近的一侧）
    panelAnchorY = dragEnd.y
    show(above: selection)
    // FR-AI.1：划词即翻（可在 设置 → AI 关闭，工具条保留手动入口）
    if aiSettings.settings.autoTranslateOnSelection {
      triggerTranslation(isAutomatic: true)
    }
  }

  // MARK: - 划词翻译（FR-AI.1）

  private func triggerTranslation(isAutomatic: Bool = false) {
    guard let pdfView,
      let rawText = pdfView.currentSelection?.string
    else { return }
    // 与 TranslationStore.translate 同一整理口径：去重比较必须用整理后的文本，
    // 否则多行选区永远匹配不上，每次 mouseUp 都重翻译（成功→翻译中→成功闪烁）
    let text = TranslationTextNormalizer.normalize(rawText)
    guard !text.isEmpty else { return }
    Logger.ai.debug("[TR ctrl] 触发翻译 auto=\(isAutomatic) \(text.count) 字 phase=\(String(describing: self.translationStore.phase), privacy: .public)")
    // 同一文本翻译途中不重复触发（点击工具条翻译按钮会伴随一次全局 mouseUp 回调）
    if case .translating = translationStore.phase, translationStore.sourceText == text {
      Logger.ai.debug("[TR ctrl] 去重：同文本翻译中")
      return
    }
    // 自动触发跳过已成功展示的同文本：PDF 上任意 mouseUp 都会走到这，
    // 否则译文出来后被下一次点击打回"翻译中"，而新任务不重启时即永转
    if isAutomatic, case .success = translationStore.phase, translationStore.sourceText == text {
      Logger.ai.debug("[TR ctrl] 去重：同文本已成功")
      return
    }
    // AI 引擎首次使用需隐私确认（选中文本将发往第三方 Provider）；
    // 自动触发不轰炸（会话级已拒则静默落失败态），手动点击仍会再弹
    if aiSettings.settings.translationEngine == .ai,
      !AIPrivacyGate.ensureAcknowledged(store: aiSettings, allowPrompt: !isAutomatic)
    {
      translationStore.presentFailure(String(localized: "已取消翻译：首次使用 AI 功能需确认隐私告知"), for: text)
      return
    }
    translationStore.translate(text)
  }

  /// 翻译状态变化后面板尺寸已变，按当前选区重新定位（仍夹取在视图范围内）
  private func relayoutPanel() {
    guard let pdfView, let hostingView, !hostingView.isHidden,
      let selection = pdfView.currentSelection
    else { return }
    hostingView.layoutSubtreeIfNeeded()
    show(above: selection)
  }

  /// 面板在选区的哪一侧（首次出现时定夺，同一选区内尺寸变化不换边，防「翻译中→译文」跳变）
  private var panelSide: PanelSide?
  /// 松手点的视图坐标 y（定位算法的鼠标侧判据；顺着手拖方向，松手点一般在选区末端）
  private var panelAnchorY: CGFloat?
  /// 面板最大预估高度（工具条 40 + 间距 6 + 气泡头/边距 ~44 + 译文上限 240）：
  /// 定位按最大高度一次定边，译文出来尺寸变化不再换边
  private static let maxPanelHeight: CGFloat = 330

  private enum PanelSide {
    case above, below
  }

  private func show(above selection: PDFSelection) {
    guard let pdfView, let hostingView,
      let page = selection.pages.last
    else { return }
    let pageBounds = selection.bounds(for: page)
    let viewBounds = pdfView.convert(pageBounds, from: page)
    let size = hostingView.fittingSize
    // 几何守卫：选区 bounds 可能是 CGRect.null（无穷原点），页→视图仿射变换后
    // 会算出 NaN；AppKit 的 setFrame 遇非法几何直接 trap 崩溃
    //（实测 "Invalid view geometry: x is NaN"）。非法输入一律不显示面板
    guard Self.isDisplayableGeometry(viewBounds: viewBounds, panelSize: size, container: pdfView.bounds) else {
      hide()
      return
    }
    let width = min(size.width, pdfView.bounds.width - 16)
    let maxY = max(pdfView.bounds.height - size.height - 8, 8)
    // 选区上方居中，水平夹取在视图内
    var origin = NSPoint(x: viewBounds.midX - width / 2, y: 0)
    origin.x = min(max(origin.x, 8), max(pdfView.bounds.width - width - 8, 8))
    if panelSide == nil {
      // 定边三因素：① 鼠标侧优先（松手点在哪侧放哪侧，离手最近）；
      // ② 该侧按最大高度放得下才用（面板向选区外侧生长，不盖选区）；
      // ③ 放不下退到空间更大的一侧（两侧都不够时夹进视图，可见优先）
      let required = min(Self.maxPanelHeight, pdfView.bounds.height - 16)
      let spaceAbove = pdfView.bounds.height - viewBounds.maxY
      let spaceBelow = viewBounds.minY
      let mouseAbove = (panelAnchorY ?? viewBounds.midY) > viewBounds.midY
      if mouseAbove {
        panelSide = spaceAbove >= required ? .above : (spaceBelow > spaceAbove ? .below : .above)
      } else {
        panelSide = spaceBelow >= required ? .below : (spaceAbove > spaceBelow ? .above : .below)
      }
    }
    // 垂直方向：按定夺侧摆放后夹取进视图（侧不变，仅位置夹取，杜绝换边跳变）
    switch panelSide {
    case .above, .none:
      origin.y = min(viewBounds.maxY + 8, maxY)
    case .below:
      origin.y = max(viewBounds.minY - size.height - 8, 8)
    }
    origin.y = min(max(origin.y, 8), maxY)
    hostingView.frame = NSRect(origin: origin, size: NSSize(width: width, height: size.height))
    hostingView.isHidden = false
    // 不在此重排 z 序：全局 mouseUp 监听先于按钮事件分派，此刻摘挂工具条
    // 会取消进行中的点击（点标注按钮无效的根因之一）。z 序由
    // rebuildCommentCards 末尾的 restackOverlays 统一维护（隐藏视图同样参与排序）
    syncCursorRects()
  }

  /// 面板定位的几何合法性（纯函数可单测）：任一输入非有限（选区 bounds 为
  /// CGRect.null 时页→视图变换会产出 NaN/inf）或容器过窄，都不得交给 setFrame——
  /// AppKit 对非法几何直接 trap（实测崩在 "Invalid view geometry: x is NaN"）
  nonisolated static func isDisplayableGeometry(
    viewBounds: NSRect, panelSize: NSSize, container: NSRect
  ) -> Bool {
    let values = [
      viewBounds.origin.x, viewBounds.origin.y, viewBounds.width, viewBounds.height,
      panelSize.width, panelSize.height, container.width, container.height,
    ]
    guard values.allSatisfy({ $0.isFinite }) else { return false }
    // 容器要装得下夹取后的最小面板（宽 16pt 余量 + 上下各 8pt）
    return container.width > 16 && container.height > 16 && panelSize.width > 0 && panelSize.height > 0
  }

  private func hide() {
    hostingView?.isHidden = true
    panelSide = nil
    panelAnchorY = nil
    translationStore.reset()
    syncCursorRects()
  }

  /// 浮动面板的工具条区高度（手型光标只给这一条；翻译气泡正文用 I 形文本光标）
  private static let toolbarStripHeight: CGFloat = 40
  /// 气泡头部按钮区（复制/关闭）相对面板顶部的偏移与尺寸（工具条 40 + 间距 6 + 头部 26）
  private static let bubbleHeaderHeight: CGFloat = 26
  private static let bubbleHeaderButtonsWidth: CGFloat = 62

  /// 把可见浮动层的 frame 同步给 ZoomablePDFView 的手型光标区域
  private func syncCursorRects() {
    guard let zoomable = pdfView as? ZoomablePDFView else { return }
    var rects: [CGRect] = []
    if let hostingView, !hostingView.isHidden {
      let frame = hostingView.frame
      // 只取顶部工具条条带（AppKit y 轴向上，工具条在面板顶=maxY 侧）：
      // 整条都报手型会让翻译气泡正文也显示小手（应为 I 形文本光标）
      let strip = min(Self.toolbarStripHeight, frame.height)
      rects.append(NSRect(x: frame.minX, y: frame.maxY - strip, width: frame.width, height: strip))
      // 气泡可见时，头部复制/关闭按钮区也报手型（正文文本区不在其内）
      if frame.height > strip + 10 {
        rects.append(NSRect(
          x: frame.maxX - Self.bubbleHeaderButtonsWidth,
          y: frame.maxY - strip - Self.bubbleHeaderHeight,
          width: Self.bubbleHeaderButtonsWidth,
          height: Self.bubbleHeaderHeight
        ))
      }
    }
    if let deleteHosting, !deleteHosting.isHidden {
      rects.append(deleteHosting.frame)
    }
    zoomable.handCursorRects = rects
  }

  // MARK: - 标注动作

  private func apply(kind: AnnotationKind) {
    guard let pdfView, let selection = pdfView.currentSelection else { return }
    // 批注（FR-4.3）：页边插框 + 虚线连接内容块
    if kind == .freeText {
      createComment(anchoredTo: selection)
      pdfView.clearSelection()
      hide()
      return
    }
    let color = store.colorsByKind[kind]?.nsColor ?? .yellow
    let subtype: PDFAnnotationSubtype
    switch kind {
    case .highlight: subtype = .highlight
    case .underline: subtype = .underline
    case .strikeOut: subtype = .strikeOut
    default: return
    }
    var created = 0
    // 一次动作创建的多行标注共享组 ID（点选删除时整体移除）
    let groupID = UUID().uuidString
    // 逐行创建：整页包围盒会让高亮铺满整行、下划线/删除线只落在最底行
    for lineSelection in selection.selectionsByLine() {
      for page in lineSelection.pages {
        var bounds = lineSelection.bounds(for: page)
        guard !bounds.isNull, !bounds.isEmpty else { continue }
        switch kind {
        case .highlight:
          // 上下各缩 14%：高亮贴合文字，相邻行不再互相叠块
          let shrink = bounds.height * 0.14
          bounds = NSRect(
            x: bounds.minX,
            y: bounds.minY + shrink,
            width: bounds.width,
            height: bounds.height * 0.72
          )
        case .strikeOut:
          // 删除线画在包围盒中部；行包围盒顶部含行距导致偏上，裁掉上部下移。
          // 0.8 → 线位于行底 40% 处（0.72 时个别粗体行落到了行底像下划线）
          bounds = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: bounds.height * 0.8
          )
        default:
          break
        }
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = color
        annotation.userName = groupID
        store.add(annotation, to: page)
        created += 1
      }
    }
    if created > 0 {
      Logger.pdf.debug("添加文本标注[\(kind.rawValue)]: \(created) 行")
      pdfView.setNeedsDisplay(pdfView.bounds)
    }
    pdfView.clearSelection()
    hide()
  }

  // MARK: - 点选删除

  /// 点选状态：同组标注（一次创建的整体）
  private var hitAnnotations: [PDFAnnotation] = []
  /// 虚线框覆盖层
  private var borderViews: [NSView] = []
  /// 编辑条（光标旁：四色改色 + 删除）
  private var deleteHosting: NSHostingView<AnnotationEditBarView>?
  /// 编辑条最后落点（改色后原位重建，位置不跳）
  private var editBarPoint: NSPoint = .zero

  /// 按下既有标注：虚线框 + 删除按钮（mouseDown 通道，见 onAnnotationMouseDown 注释）
  private func handleAnnotationMouseDown(at point: NSPoint) {
    guard let pdfView else { return }
    // 落在删除按钮上：交给按钮自身处理，不再走标注命中（否则会点到按钮背后的标注）
    if let deleteHosting, !deleteHosting.isHidden, deleteHosting.frame.contains(point) {
      return
    }
    // 任意点击先收起（空白处点击即消失）
    hideDelete()
    guard let page = pdfView.page(for: point, nearest: false),
      let document = pdfView.document
    else { return }
    let pagePoint = pdfView.convert(point, to: page)
    guard var annotation = page.annotation(at: pagePoint) else { return }
    // 点中 Popup 伴侣窗口时按标记本体处理
    if annotation.isPopup,
      let parent = page.annotations.first(where: { $0.popup === annotation })
    {
      annotation = parent
    }
    // 批注标记的点击已在 mouseDown 层处理并吞掉事件——这里再处理会双开 popover（闪两次动画）
    if annotation.isCommentMarker { return }
    // 只认自己管理的标注：PDF 自带的 Link（目录/选项行常铺满不可见链接）、表单域、
    // 图形标注等不得进点选删除——否则点目录跳转后会冒出红虚线框 + 垃圾桶（实测）
    guard Self.isManagedAnnotation(annotation) else { return }
    // 整体：同组 ID 的标注一起框选、一起删除
    let group = groupAnnotations(matching: annotation, in: document)
    // 点中批注的高亮/虚线 → 同样打开编辑框（FR-4.3）
    if let marker = group.first(where: { $0.isCommentMarker || AnnotationKind.of($0) == .freeText }) {
      edit(comment: marker)
      return
    }
    hitAnnotations = group
    showDashedBorders(around: hitAnnotations)
    showEditBar(at: point)
  }

  /// 命中组里可改色的标注（文本标记类）；空 = 编辑条只显示删除
  private var recolorableHits: [PDFAnnotation] {
    hitAnnotations.filter { annotation in
      guard let kind = AnnotationKind.of(annotation) else { return false }
      return AnnotationColor.recolorableKinds.contains(kind)
    }
  }

  /// 是否本 App 管理的标注（纯函数可单测）：只有它们参与点选删除/改色。
  /// PDF 自带的 Link/表单域/图形标注一律排除——它们不是用户在本 App 里标的
  nonisolated static func isManagedAnnotation(_ annotation: PDFAnnotation) -> Bool {
    annotation.isAppManaged
  }

  /// 把命中组改成指定色（FR-4.4）：逐个写回 + 重绘；编辑条留在原位以便连续试色
  private func recolorHits(to color: AnnotationColor) {
    let targets = recolorableHits
    guard !targets.isEmpty else { return }
    for annotation in targets {
      store.update(annotation) { $0.color = color.nsColor }
    }
    // 重绘必须走 documentView 通道（同 deleteHit）：只标脏 PDFView 自己不会重画标注层，
    // 改色后旧颜色会残留到下一次滚动/缩放刷新
    var touched: [PDFPage] = []
    for annotation in targets {
      if let page = annotation.page, !touched.contains(where: { $0 === page }) {
        touched.append(page)
      }
    }
    redraw(pages: touched)
    // 当前色标记随之更新（rootView 重建，位置不动）
    showEditBar(at: editBarPoint)
  }

  /// 按组 ID 收集同组标注（无组 ID 的单标注返回自身；作者名 userName 不算组 ID）
  private func groupAnnotations(matching annotation: PDFAnnotation, in document: PDFDocument) -> [PDFAnnotation] {
    guard isAnnotationGroupID(annotation.userName) else { return [annotation] }
    let groupID = annotation.userName!
    var result: [PDFAnnotation] = []
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      result += page.annotations.filter { $0.userName == groupID }
    }
    return result.isEmpty ? [annotation] : result
  }

  /// 围绕每个同组标注画红色虚线框（用户可见整体范围；不拦截点击）
  private func showDashedBorders(around annotations: [PDFAnnotation]) {
    guard let pdfView else { return }
    for annotation in annotations {
      guard let page = annotation.page else { continue }
      let viewBounds = pdfView.convert(annotation.bounds, from: page).insetBy(dx: -2, dy: -2)
      let border = PassthroughView(frame: viewBounds)
      border.wantsLayer = true
      let shape = CAShapeLayer()
      shape.path = CGPath(rect: border.bounds, transform: nil)
      shape.fillColor = nil
      shape.strokeColor = NSColor.systemRed.cgColor
      shape.lineWidth = 1.2
      shape.lineDashPattern = [4, 3]
      border.layer?.addSublayer(shape)
      overlayParent?.addSubview(border)
      borderViews.append(border)
    }
  }

  /// 编辑条出现在光标旁（夹取在视图内；置顶于虚线框之上）。
  /// 文本标记类给四色改色 + 删除，其余只给删除；改色后原位重建以更新「当前色」标记
  private func showEditBar(at point: NSPoint) {
    guard let pdfView else { return }
    editBarPoint = point
    let currentColor = recolorableHits.first.map { AnnotationColor.closest(to: $0.color) }
    let rootView = AnnotationEditBarView(
      currentColor: currentColor,
      onPick: { [weak self] color in
        self?.recolorHits(to: color)
      },
      onDelete: { [weak self] in
        self?.deleteHit()
      }
    )
    if let deleteHosting {
      deleteHosting.rootView = rootView
    } else {
      let hosting = NSHostingView(rootView: rootView)
      overlayParent?.addSubview(hosting)
      deleteHosting = hosting
    }
    guard let deleteHosting else { return }
    let size = deleteHosting.fittingSize
    var origin = NSPoint(x: point.x + 8, y: point.y + 8)
    origin.x = min(max(origin.x, 4), pdfView.bounds.width - size.width - 4)
    origin.y = min(max(origin.y, 4), pdfView.bounds.height - size.height - 4)
    deleteHosting.frame = NSRect(origin: origin, size: size)
    deleteHosting.isHidden = false
    // 置顶（编辑条在 mouseDown 时段显示，此刻无覆盖层点击在途，安全；
    // 不走 restackOverlays——统一重排会波及工具条等其它视图）
    overlayParent?.addSubview(deleteHosting, positioned: .above, relativeTo: nil)
    syncCursorRects()
  }

  private func deleteHit() {
    guard let pdfView, let document = pdfView.document else { return }
    var touched: [PDFPage] = []
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      for annotation in hitAnnotations where annotation.page === page {
        store.remove(annotation, from: page)
        if !touched.contains(where: { $0 === page }) {
          touched.append(page)
        }
      }
    }
    redraw(pages: touched)
    hideDelete()
  }

  /// 标注增删后立刻重画（只涉及改动过的那几页，实际绘制仅发生在可见区域，开销可忽略）。
  /// 关键是失效通知要打在 documentView 上——页面是画在 PDFView 的内层文档视图里的，
  /// 只标脏 PDFView 自己不会重画标注层，实测删掉批注后高亮/虚线/图标要等下一次刷新才消失
  private func redraw(pages: [PDFPage]) {
    guard let pdfView else { return }
    for page in pages {
      pdfView.annotationsChanged(on: page)
    }
    if let documentView = pdfView.documentView {
      documentView.setNeedsDisplay(documentView.bounds)
    }
    pdfView.setNeedsDisplay(pdfView.bounds)
  }

  private func hideDelete() {
    hitAnnotations = []
    for border in borderViews {
      border.removeFromSuperview()
    }
    borderViews = []
    deleteHosting?.isHidden = true
    syncCursorRects()
    // 编辑条收起 = 交互结束：把改色期间攒下的重扫与写回排上
    store.resumeDeferredWrites()
  }

  // MARK: - 批注（FR-4.3）

  /// 正在编辑的批注标记
  // MARK: - 页边批注卡片（显示层）

  /// 卡片槽位：marker（数据与锚点）+ hosting（显示）；几何每次从页坐标现算
  private struct CommentCardSlot {
    let marker: PDFAnnotation
    let hosting: NSHostingView<CommentCardView>
    /// 连接线的内容端锚点（页坐标）：x = 内容近侧边缘，y = 内容行中心。
    /// 优先取同组正文高亮；无高亮的组退用旧版虚线点标注的远端点
    let anchor: NSPoint?
    let isLeftMargin: Bool
  }

  private var commentCards: [CommentCardSlot] = []
  private var commentCardCancellable: AnyCancellable?
  /// 可见页签名（页索引序列）：变化时才重建卡片（翻页换内容；缩放/滚动只重摆）
  private var visiblePagesSignature = ""
  /// 本次重建做过旧数据迁移（藏图标/清点线）的页——重建后统一标脏重绘
  private var migratedPages: Set<PDFPage> = []
  /// 连接虚线层（内容边缘 → 卡片近边；随卡片布局动态重绘）
  private var connectorLayer: CommentConnectorLayer?
  /// 页面文本行矩形缓存（页坐标）：卡片净空按「真实正文」计算——
  /// 批注自身锚点算出的边距可能小于页面上更靠边的其他文字（实测遮挡根因）
  private var pageLinesCache: [ObjectIdentifier: [NSRect]] = [:]

  private func textLineRects(for page: PDFPage) -> [NSRect] {
    let key = ObjectIdentifier(page)
    if let cached = pageLinesCache[key] { return cached }
    let rects = (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [])
      .map { $0.bounds(for: page) }
      .filter { !$0.isNull && $0.width > 1 && $0.height > 1 }
    pageLinesCache[key] = rects
    return rects
  }

  /// 卡片纵向带 [yLower, yUpper]（页坐标）内，该侧最近正文行允许的最大卡片宽（页单位）
  private func textClearanceWidth(
    on page: PDFPage, isLeft: Bool, yLower: CGFloat, yUpper: CGFloat
  ) -> CGFloat? {
    var nearest: CGFloat = isLeft ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude
    for rect in textLineRects(for: page) where rect.midY >= yLower && rect.midY <= yUpper {
      nearest = isLeft ? min(nearest, rect.minX) : max(nearest, rect.maxX)
    }
    guard nearest.isFinite else { return nil }
    let pageBounds = page.bounds(for: .cropBox)
    return isLeft ? nearest - pageBounds.minX : pageBounds.maxX - nearest
  }
  /// 批注页面标记色（内容虚线框 + 连接线）：固定橙色——不在四色板内，
  /// 与高亮的四色体系彻底区分（“这是批注”的专属签名色）
  static let commentMarkColor = NSColor.systemOrange

  /// 卡片观察接线：标注增删改（revision）→ 重建可见卡片；
  /// 缩放/翻页/滚动/改帧 → 只重摆（setFrame + rootView 换尺寸参数）
  private func setupCommentCards() {
    guard let pdfView else { return }
    commentCardCancellable = store.$revision
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.rebuildCommentCards() }
    for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(commentCardsLayoutChanged), name: name, object: pdfView
      )
    }
    pdfView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(commentCardsLayoutChanged),
      name: NSView.frameDidChangeNotification, object: pdfView
    )
    let layer = CommentConnectorLayer()
    layer.frame = pdfView.bounds
    layer.autoresizingMask = [.width, .height]
    // 自绘内容同样裁到自身 bounds（防 drawRect 路径绕过默认裁剪溢出到标签栏）
    layer.clipsToBounds = true
    overlayParent?.addSubview(layer)
    connectorLayer = layer
    // 滚动跟随：PDFView 没有滚动通知，监听内部文档滚动视图裁剪区的 bounds 变化
    if let clip = pdfView.subviews.compactMap({ $0 as? NSScrollView }).first?.contentView {
      clip.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(commentCardsLayoutChanged),
        name: NSView.boundsDidChangeNotification, object: clip
      )
    }
    rebuildCommentCards()
  }

  @objc private func commentCardsLayoutChanged() {
    guard let pdfView else { return }
    let signature = pdfView.visiblePages
      .compactMap { pdfView.document?.index(for: $0) }
      .map(String.init)
      .joined(separator: ",")
    if signature != visiblePagesSignature {
      visiblePagesSignature = signature
      rebuildCommentCards()
    } else {
      updateCommentCardFrames()
    }
  }

  /// 覆盖层 z 序固定（自下而上）：连线层 → 批注卡片 → 点选虚线边框 →
  /// 编辑条 → 浮动工具条。addSubview 恒置顶，卡片随 revision 全量重建后
  /// 会垫到工具条上方（虚线框/卡片盖住工具条、撑出 PDF 区的根因），
  /// 每次覆盖层增删后统一重排
  private func restackOverlays() {
    guard let parent = overlayParent else { return }
    let order: [NSView?] =
      [connectorLayer]
      + commentCards.map(\.hosting)
      + borderViews
      + [deleteHosting, hostingView]
    for case let view? in order where view.superview === parent {
      view.removeFromSuperview()
      parent.addSubview(view)
    }
  }

  /// 全量重建：清空后为「可见页」的每个批注标记建卡（数量小，直接全建）
  private func rebuildCommentCards() {
    guard let pdfView else { return }
    visiblePagesSignature = pdfView.visiblePages
      .compactMap { pdfView.document?.index(for: $0) }
      .map(String.init)
      .joined(separator: ",")
    for slot in commentCards {
      slot.hosting.removeFromSuperview()
    }
    commentCards = []
    for page in pdfView.visiblePages {
      let pageBounds = page.bounds(for: pdfView.displayBox)
      for marker in page.annotations where marker.isCommentMarker {
        let isLeft = marker.bounds.midX < pageBounds.midX
        // 内容锚点（页坐标）：高亮合集的近侧边缘 + 行中心；无高亮退用旧虚线点远端
        var anchor: NSPoint? = nil
        var legacyDots: [PDFAnnotation] = []
        var contentUnion: CGRect? = nil
        for annotation in page.annotations where annotation.userName == marker.userName {
          let kind = AnnotationKind.of(annotation)
          guard kind == .highlight || kind == .underline else { continue }
          let b = annotation.bounds
          if b.width > 5 {
            contentUnion = contentUnion?.union(b) ?? b
            // 标准 underline 同时是跨阅读器可见的正文指认；旧版曾写 NoView，打开时修复。
            if PDFAnnotationStore.restorePortableVisibility(of: annotation) {
              migratedPages.insert(page)
            }
          } else if kind == .highlight, b.width < 2, b.height < 2 {
            legacyDots.append(annotation)
          }
        }
        if let union = contentUnion {
          anchor = NSPoint(
            x: isLeft ? union.minX : union.maxX,
            y: union.midY
          )
        } else if let far = legacyDots.max(by: { $0.bounds.midX * (isLeft ? 1 : -1) < $1.bounds.midX * (isLeft ? 1 : -1) }) {
          anchor = NSPoint(x: far.bounds.midX, y: far.bounds.midY)
        }
        // 页边卡片覆盖原生图标，但不能把 NoView 写进 PDF；修复旧版隐藏标记。
        if PDFAnnotationStore.restorePortableVisibility(of: marker) {
          migratedPages.insert(page)
        }
        for dot in legacyDots {
          page.removeAnnotation(dot)
          migratedPages.insert(page)
        }
        let slot = CommentCardSlot(
          marker: marker,
          hosting: NSHostingView(rootView: CommentCardView(
            text: "", color: .systemBlue, isLeftMargin: true, scale: 1, width: nil, onClick: {}
          )),
          anchor: anchor,
          isLeftMargin: isLeft
        )
        overlayParent?.addSubview(slot.hosting)
        commentCards.append(slot)
      }
    }
    if !migratedPages.isEmpty {
      for page in migratedPages {
        pdfView.annotationsChanged(on: page)
      }
      pdfView.setNeedsDisplay(pdfView.bounds)
      migratedPages.removeAll()
      // 旧版本已经把 NoView 持久化；修复后安排一次正常写回，让第三方阅读器恢复可见。
      store.markDirty()
    }
    updateCommentCardFrames()
    restackOverlays()
  }

  /// 重摆：页坐标 → 视图坐标换算卡片 frame，并按当前缩放同步 rootView 尺寸参数。
  /// 宽度 = 页缘 → 内容近侧边缘（无边距数据退化芯片，绝不盲设宽度遮正文）；
  /// 芯片/卡片不小于图标（完全盖住原生便签，杜绝「底部露一条蓝」）；
  /// 同页同侧自上而下防叠下推（图标 22pt 错位不足以错开几十 pt 高的卡片）
  private func updateCommentCardFrames() {
    guard let pdfView else { return }
    let scale = max(pdfView.scaleFactor, 0.01)
    struct Placed {
      var frame: NSRect
      let index: Int
    }
    var placed: [Placed] = []

    for (index, slot) in commentCards.enumerated() {
      guard let page = slot.marker.page else {
        slot.hosting.isHidden = true
        placed.append(Placed(frame: .zero, index: index))
        continue
      }
      let viewMarker = pdfView.convert(slot.marker.bounds, from: page)
      let viewPage = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
      guard viewMarker.isFiniteRect, viewPage.isFiniteRect else {
        slot.hosting.isHidden = true
        placed.append(Placed(frame: .zero, index: index))
        continue
      }
      // 可用边距（视图单位）：页缘 → 内容近侧边缘；无内容数据 → 芯片（安全兜底）。
      /// 上限 55pt（页单位）——页边是提示区不是阅读区，宁可截断不多占
      var cardWidth: CGFloat? = nil
      var contentEdgeViewX: CGFloat? = nil
      if let anchor = slot.anchor {
        let edgeRect = pdfView.convert(
          NSRect(x: anchor.x - 0.5, y: anchor.y, width: 1, height: 1),
          from: page
        )
        if edgeRect.isFiniteRect {
          contentEdgeViewX = edgeRect.midX
          let available = slot.isLeftMargin
            ? edgeRect.midX - viewPage.minX
            : viewPage.maxX - edgeRect.midX
          var usable = available - 6 * scale
          // 文本净空（页单位）：该纵向带内最近的正文行才是硬边界——
          // 批注自身内容算的边距可能比页面上其他更靠边的文字宽（遮挡根因）
          if let clear = textClearanceWidth(
            on: page, isLeft: slot.isLeftMargin,
            yLower: slot.marker.bounds.minY - 4,
            yUpper: slot.marker.bounds.minY + 80
          ) {
            usable = min(usable, clear * scale - 6 * scale)
          }
          if usable >= 36 * scale {
            cardWidth = min(usable, 55 * scale)
          }
        }
      }

      let text = slot.marker.contents ?? ""
      let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      slot.hosting.rootView = CommentCardView(
        text: text,
        color: Self.commentMarkColor,
        isLeftMargin: slot.isLeftMargin,
        scale: scale,
        width: isEmpty ? nil : cardWidth,
        onClick: { [weak self] in self?.edit(comment: slot.marker) }
      )

      let fitted = slot.hosting.fittingSize
      let width = cardWidth ?? fitted.width
      let height = fitted.height
      guard width > 0, height > 0, width.isFinite, height.isFinite else {
        slot.hosting.isHidden = true
        placed.append(Placed(frame: .zero, index: index))
        continue
      }
      // 卡顶与图标顶对齐向下生长（非翻转系：顶缘 = maxY）
      var frame = NSRect(
        x: slot.isLeftMargin ? viewMarker.minX - 2 : viewMarker.maxX + 2 - width,
        y: viewMarker.maxY + 2 - height,
        width: width,
        height: height
      )
      frame.origin.x = min(max(frame.minX, viewPage.minX), max(viewPage.maxX - width, viewPage.minX))
      // 硬净空：卡片绝不越过内容近侧边缘（哪怕边距数据有出入）
      if let edgeX = contentEdgeViewX {
        if slot.isLeftMargin, frame.maxX > edgeX - 4 {
          frame.origin.x = max(viewPage.minX, edgeX - 4 - width)
        } else if !slot.isLeftMargin, frame.minX < edgeX + 4 {
          frame.origin.x = min(viewPage.maxX - width, edgeX + 4)
        }
      }
      placed.append(Placed(frame: frame, index: index))
    }

    // 同页同侧防叠（非翻转坐标系：y 大 = 屏幕上方，卡下缘 = minY）：
    // 自上而下，与上一张卡下缘冲突则下推 4pt；整组越出页底则整体上移夹回
    var handled = [Bool](repeating: false, count: placed.count)
    for indexA in placed.indices where commentCards[placed[indexA].index].marker.page != nil {
      if handled[indexA] { continue }
      var group = [indexA]
      for indexB in placed.indices where indexB != indexA {
        let slotA = commentCards[placed[indexA].index]
        let slotB = commentCards[placed[indexB].index]
        if !handled[indexB],
          slotA.isLeftMargin == slotB.isLeftMargin,
          slotA.marker.page === slotB.marker.page
        {
          group.append(indexB)
        }
      }
      group.sort { placed[$0].frame.maxY > placed[$1].frame.maxY }
      var previousLowerEdge: CGFloat? = nil
      for g in group {
        handled[g] = true
        if let lower = previousLowerEdge, placed[g].frame.maxY > lower {
          placed[g].frame.origin.y = lower - 4 - placed[g].frame.height
        }
        previousLowerEdge = placed[g].frame.minY
      }
      if let bottomIndex = group.last,
        let page = commentCards[placed[bottomIndex].index].marker.page
      {
        let viewPage = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        let overflow = (viewPage.minY + 2) - placed[bottomIndex].frame.minY
        if overflow > 0 {
          for g in group {
            placed[g].frame.origin.y += overflow
          }
        }
      }
    }

    let markColor = (Self.commentMarkColor.usingColorSpace(.deviceRGB) ?? .systemOrange)
    var segments: [CommentConnectorLayer.Segment] = []
    var frames: [CommentConnectorLayer.Frame] = []
    for var p in placed {
      let slot = commentCards[p.index]
      if slot.marker.page == nil || p.frame == .zero || !p.frame.isFiniteRect {
        slot.hosting.isHidden = true
        continue
      }
      slot.hosting.isHidden = false
      slot.hosting.frame = p.frame
      guard let page = slot.marker.page else { continue }
      // 终检：下推后的最终纵向带若碰到更近的正文行，收窄卡片
      let pageFrame = pdfView.convert(p.frame, to: page)
      if pageFrame.isFiniteRect,
        let clear = textClearanceWidth(
          on: page, isLeft: slot.isLeftMargin,
          yLower: pageFrame.minY, yUpper: pageFrame.maxY
        ),
        p.frame.width > clear * scale - 6 * scale
      {
        let allowed = max(clear * scale - 6 * scale, 24 * scale)
        slot.hosting.rootView = CommentCardView(
          text: slot.marker.contents ?? "",
          color: Self.commentMarkColor,
          isLeftMargin: slot.isLeftMargin,
          scale: scale,
          width: allowed,
          onClick: { [weak self] in self?.edit(comment: slot.marker) }
        )
        let refit = slot.hosting.fittingSize
        p.frame.size.width = allowed
        p.frame.size.height = refit.height
        slot.hosting.frame = p.frame
      }
      // 内容块虚线框：围住批注所指文本（组内全部数据标记的合集）
      if let content = contentUnion(of: slot, on: page) {
        let viewRect = pdfView.convert(content, from: page)
        if viewRect.isFiniteRect, viewRect.width > 4, viewRect.height > 2 {
          frames.append(.init(rect: viewRect, color: markColor))
        }
      }
      // 连接虚线：内容边缘锚点 → 卡片近边中点。同行多条批注共享起点，
      // 但各自指向卡片本体中点——支线斜率天然不同，哪条对哪卡一目了然
      //（不再产生近水平的歧义段）
      if let anchor = slot.anchor {
        let a = pdfView.convert(NSPoint(x: anchor.x, y: anchor.y), from: page)
        if a.x.isFinite, a.y.isFinite {
          let cardEdgeX = slot.isLeftMargin ? p.frame.maxX : p.frame.minX
          segments.append(.init(
            start: a,
            end: NSPoint(x: cardEdgeX, y: p.frame.midY),
            color: markColor
          ))
        }
      }
    }
    connectorLayer?.segments = segments
    connectorLayer?.frames = frames
    connectorLayer?.needsDisplay = true
  }

  /// 批注组内容块合集（页坐标）：组内宽标记（高亮/下划线，均为数据标记）bounds 并集
  private func contentUnion(of slot: CommentCardSlot, on page: PDFPage) -> CGRect? {
    var union: CGRect? = nil
    for annotation in page.annotations where annotation.userName == slot.marker.userName {
      let kind = AnnotationKind.of(annotation)
      guard kind == .highlight || kind == .underline, annotation.bounds.width > 5 else { continue }
      union = union?.union(annotation.bounds) ?? annotation.bounds
    }
    return union
  }

  private var editingComment: PDFAnnotation?
  private var commentPopover: NSPopover?
  /// 编辑中的草稿（关闭时一次性写回标注，打字不触碰 PDFKit）
  private var commentDraft: CommentDraft?

  /// 批注图标尺寸（页坐标）
  private static let commentIconSize: CGFloat = 22
  /// 图标距页缘
  private static let commentInset: CGFloat = 4
  /// 点状虚线：1.1pt 小方块、间距 4pt（细长小高亮矩形拼成——PDFKit 不渲染程序化 Line/Ink，实测）
  private static let commentDashSize: CGFloat = 1.1
  private static let commentDashStep: CGFloat = 4

  /// 划词创建批注（FR-4.3）：
  /// 页缘放便签图标（不显示内容，点击才弹出编辑框；位置只跟随内容块垂直中心，
  /// 与选区宽度无关，永不遮挡正文）+ 点状虚线直线连接（内容块边缘 → 图标中心，
  /// 排队错位时斜线指认关系）+ 选中内容逐行高亮（FR-4.1 视觉），三者同组。
  /// 左右侧严格按内容块中线判定（双栏论文左栏→左边栏、右栏→右边栏）。
  private func createComment(anchoredTo selection: PDFSelection) {
    guard let pdfView, let page = selection.pages.first else { return }
    let anchor = selection.bounds(for: page)
    guard !anchor.isNull, !anchor.isEmpty else { return }
    // 必须用显示盒（默认 cropBox）算页边：mediaBox 与显示区域不一致时坐标错位
    let pageBounds = page.bounds(for: pdfView.displayBox)
    let isLeft = anchor.midX < pageBounds.midX
    let size = Self.commentIconSize
    let x = isLeft ? pageBounds.minX + Self.commentInset : pageBounds.maxX - Self.commentInset - size
    var y = anchor.midY - size / 2
    y = Self.avoidIconCollision(
      initialY: y,
      size: size,
      existingRects: page.annotations.filter { $0.isCommentMarker }.map(\.bounds)
    )
    y = min(max(y, pageBounds.minY + 4), pageBounds.maxY - size - 4)

    let groupID = UUID().uuidString
    let palette = store.colorsByKind[.freeText]?.nsColor ?? .systemBlue

    // 批注标记（先创建：列表条目以其为主标注）
    let marker = PDFAnnotation(
      bounds: NSRect(x: x, y: y, width: size, height: size),
      forType: .text,
      withProperties: nil
    )
    marker.iconType = .comment
    marker.color = palette
    marker.userName = groupID
    marker.contents = ""
    // 原生便签保持标准可见性，页边卡片在本 App 内覆盖它；这样导出的 PDF
    // 在 Preview/Acrobat 中仍有可点击的便签图标。
    store.add(marker, to: page)
    // PDFKit 添加 /Text 会自动补 Popup 伴侣：仅 shouldDisplay=false 仍参与命中测试，
    // PDFView 会给它画带手柄的原生选中框并吃掉那块区域的划词——直接从页面摘除
    if let popup = marker.popup {
      (popup as? PDFAnnotationPopup)?.isOpen = false
      popup.shouldDisplay = false
      page.removeAnnotation(popup)
    }

    // 连接虚线不再入库（旧实现是几十个 1.1pt 点标注，卡片错位后指不对、
    // 还污染标注列表）——由卡片覆盖层动态绘制（见 CommentConnectorLayer）

    // 选中内容同步下划线（与卡片视觉协调的正文标记）
    let highlighted = underlineLines(of: selection, color: palette, groupID: groupID)

    Logger.pdf.debug("添加批注[\(isLeft ? "左" : "右")边栏]: 页 \((pdfView.document?.index(for: page) ?? 0) + 1)，anchor=\(NSStringFromRect(anchor))，page=\(NSStringFromRect(pageBounds))，icon=\(NSStringFromRect(marker.bounds))，下划线 \(highlighted) 行")
    pdfView.setNeedsDisplay(pdfView.bounds)
    edit(comment: marker)
  }

  /// 批注正文数据标记：逐行下划线（bounds 用作锚点/内容范围数据）。
  /// 不显示——正文指认视觉由覆盖层的虚线圆角框承担（FR-4.3 与卡片协调，
  /// PDFKit 程序化 Square/Line 实测不渲染，色块高亮又过重）；
  /// 高亮工具 FR-4.1 的色块路径不受影响
  @discardableResult
  private func underlineLines(of selection: PDFSelection, color: NSColor, groupID: String) -> Int {
    var created = 0
    for lineSelection in selection.selectionsByLine() {
      for page in lineSelection.pages {
        let bounds = lineSelection.bounds(for: page)
        guard !bounds.isNull, !bounds.isEmpty else { continue }
        let annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
        annotation.color = color
        annotation.userName = groupID
        store.add(annotation, to: page)
        created += 1
      }
    }
    return created
  }

  /// 与同页既有批注图标纵向避让（往下挪，最多 20 轮防极端堆叠死循环）。
  /// 20 轮耗尽（密集堆叠）时兜底放到全部既有图标下方——绝不重叠：
  /// 重叠让点选命中歧义，点新图标实际编辑旧标注（内容串台，实测）
  nonisolated static func avoidIconCollision(
    initialY: CGFloat, size: CGFloat, existingRects: [CGRect]
  ) -> CGFloat {
    var y = initialY
    var rect = NSRect(x: 0, y: y, width: size, height: size)
    for _ in 0..<20 {
      guard let collision = existingRects.first(where: { $0.intersects(rect) }) else { return y }
      y = collision.minY - size - 4
      rect.origin.y = y
    }
    // 轮数耗尽：挪到全部既有图标之下（minY 最小者再往下）
    let lowest = existingRects.map(\.minY).min() ?? y
    return min(lowest - size - 4, y)
  }

  /// 命中批注标记（含 Popup 伴侣反查），未命中返回 nil
  private func markerAt(viewPoint point: NSPoint) -> PDFAnnotation? {
    guard let pdfView,
      let page = pdfView.page(for: point, nearest: false)
    else { return nil }
    var hit = page.annotation(at: pdfView.convert(point, to: page))
    // 点中 Popup 伴侣窗口时按标记本体处理（无 parent 属性，反查）
    if let popup = hit, popup.isPopup,
      let parent = page.annotations.first(where: { $0.popup === popup })
    {
      hit = parent
    }
    return hit?.isCommentMarker == true ? hit : nil
  }

  /// 批注图标的 mouseDown 拦截：命中标记 → 开编辑框并吞掉事件
  private func handleMarkerMouseDown(at point: NSPoint) -> Bool {
    guard let marker = markerAt(viewPoint: point) else { return false }
    hideDelete()
    edit(comment: marker)
    return true
  }

  /// 弹出批注编辑框（锚定图标，朝页面内容一侧展开）
  private func edit(comment marker: PDFAnnotation) {
    guard let pdfView, let page = marker.page else { return }
    // 上一个编辑还挂着（popover 打开或关闭动画未走完）：必须同步先落定旧草稿——
    // 旧 popover 的 willClose 是异步到达的，等到那时 commentPopover 已被替换，
    // 身份闸必然失败：旧草稿既不落定也不丢弃，且旧 popover 若因新 show 暂缓仍挂在
    // 屏上，用户敲的是过期草稿，落定时还会把旧内容写进新标注（实测内容串台）
    if let oldPopover = commentPopover {
      finishCommentEditing(for: oldPopover)
      oldPopover.close()  // finish 已清引用，用保存的引用物理关闭旧 popover
    }
    // 撤下创建时已排的落盘：否则那次写回正好砸在编辑框出现、光标该闪的时刻
    store.deferPendingWrites()
    // 点击图标可能刚把原生 Popup 伴侣窗打开，压掉（编辑统一走我们的 popover）
    if let popup = marker.popup {
      (popup as? PDFAnnotationPopup)?.isOpen = false
      popup.shouldDisplay = false
      pdfView.setNeedsDisplay(pdfView.bounds)
    }
    editingComment = marker
    let draft = CommentDraft(marker.contents ?? "")
    commentDraft = draft
    let popover = NSPopover()
    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = NSHostingController(rootView: CommentEditorView(
      draft: draft,
      onDelete: { [weak self] in
        self?.deleteComment(marker)
      },
      onCommit: { [weak self] in
        // ↵ = 提交并关闭（内容由 popoverDidClose 一次性写回，同点击空白处）
        self?.commentPopover?.close()
      }
    ))
    let isLeft = marker.bounds.midX < page.bounds(for: pdfView.displayBox).midX
    commentPopover = popover
    // 锚点优先正文内容块（用户视线所在；放大后页缘标记可能在视口外，
    // 锚它会把弹窗定位到窗外——「缩放后批注弹窗出不来」的根因）；
    // 内容块也不可见（滚动脱离）则先滚到标记处再弹
    let visible = pdfView.bounds
    let contentRect = contentUnionViewRect(of: marker)
    if let content = contentRect, visible.intersects(content.insetBy(dx: -10, dy: -10)) {
      DispatchQueue.main.async {
        popover.show(relativeTo: content, of: pdfView, preferredEdge: isLeft ? .maxX : .minX)
      }
    } else {
      let markerRect = pdfView.convert(marker.bounds, from: page)
      if visible.insetBy(dx: -20, dy: -20).intersects(markerRect) {
        DispatchQueue.main.async {
          self.presentEditPopover(popover, marker: marker, isLeft: isLeft)
        }
      } else {
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: marker.bounds.midX, y: marker.bounds.midY)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
          self?.presentEditPopover(popover, marker: marker, isLeft: isLeft)
        }
      }
    }
  }

  /// 弹出编辑框（锚点现算 + 视口夹取兜底：滚动/布局变动后标记仍可能在视口外，
  /// 原样锚定会把弹窗定位到窗外出不来）
  private func presentEditPopover(_ popover: NSPopover, marker: PDFAnnotation, isLeft: Bool) {
    guard let pdfView, let page = marker.page else { return }
    var anchor = pdfView.convert(marker.bounds, from: page)
    let visible = pdfView.bounds
    if !visible.intersects(anchor) {
      anchor.origin.x = min(max(anchor.minX, visible.minX + 8), max(visible.minX + 8, visible.maxX - anchor.width - 8))
      anchor.origin.y = min(max(anchor.minY, visible.minY + 8), max(visible.minY + 8, visible.maxY - anchor.height - 8))
    }
    popover.show(relativeTo: anchor, of: pdfView, preferredEdge: isLeft ? .maxX : .minX)
  }

  /// 批注组正文内容块（视图坐标）：组内高亮/下划线合集换算；弹窗锚点用
  private func contentUnionViewRect(of marker: PDFAnnotation) -> NSRect? {
    guard let pdfView, let page = marker.page else { return nil }
    var union: NSRect? = nil
    for annotation in page.annotations where annotation.userName == marker.userName {
      let kind = AnnotationKind.of(annotation)
      guard kind == .highlight || kind == .underline, annotation.bounds.width > 5 else { continue }
      union = union?.union(annotation.bounds) ?? annotation.bounds
    }
    guard let u = union else { return nil }
    let rect = pdfView.convert(u, from: page)
    return rect.isFiniteRect ? rect : nil
  }

  /// 删除整条批注（图标 + 虚线段 + 高亮，同组；Popup 伴侣由 store.remove 连带）
  private func deleteComment(_ marker: PDFAnnotation) {
    guard let pdfView, let document = pdfView.document else { return }
    var touched: [PDFPage] = []
    for annotation in groupAnnotations(matching: marker, in: document) {
      if let page = annotation.page {
        store.remove(annotation, from: page)
        if !touched.contains(where: { $0 === page }) {
          touched.append(page)
        }
      }
    }
    editingComment = nil
    redraw(pages: touched)
    commentPopover?.close()
    commentPopover = nil
  }

  /// 编辑框关闭时仍为空 → 整条移除（避免残留空图标）
  private func discardCommentIfEmpty(_ marker: PDFAnnotation) {
    guard (marker.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let document = pdfView?.document
    else { return }
    var touched: [PDFPage] = []
    for annotation in groupAnnotations(matching: marker, in: document) {
      if let page = annotation.page {
        store.remove(annotation, from: page)
        if !touched.contains(where: { $0 === page }) {
          touched.append(page)
        }
      }
    }
    redraw(pages: touched)
  }
}

extension AnnotationToolbarController: NSPopoverDelegate {
  /// 光标定位用的 UTF-16 长度（Bug 修复 5）：NSTextView.setSelectedRange 按 UTF-16 计数，
  /// String.count 是 Character 数——含 emoji（占 2 个 UTF-16 码元）时光标会落进文本中间
  static func utf16Length(of string: String) -> Int {
    (string as NSString).length
  }

  /// 弹出完成后把焦点放进文本区（新建/编辑都直接出光标）
  func popoverDidShow(_ notification: Notification) {
    guard let view = commentPopover?.contentViewController?.view,
      let textView = view.firstDescendant(of: NSTextView.self)
    else { return }
    view.window?.makeFirstResponder(textView)
    // 光标移到文末并显式重启闪烁——否则插入点要等首次击键才出现
    textView.setSelectedRange(NSRange(location: Self.utf16Length(of: textView.string), length: 0))
    textView.updateInsertionPointStateAndRestartTimer(true)
  }

  func popoverWillClose(_ notification: Notification) {
    // 提前到 willClose：didClose 要等关闭动画走完才到，那段时间页面上的高亮/虚线/图标
    // 白白多赖着（用户看到编辑框已关而标注还在）
    finishCommentEditing(for: notification.object as? NSPopover)
  }

  func popoverDidClose(_ notification: Notification) {
    finishCommentEditing(for: notification.object as? NSPopover)
  }

  /// 落定批注内容并收尾（幂等）。只认当前那个 popover——`edit(comment:)` 会先关掉上一个，
  /// 它迟到的 didClose 不能把新开的这条误当成自己落定
  private func finishCommentEditing(for popover: NSPopover?) {
    guard let popover, popover === commentPopover else { return }
    // 先清引用再落盘：isInteracting 据此判定交互已结束，否则 update 只标脏不写
    let marker = editingComment
    let draft = commentDraft
    editingComment = nil
    commentDraft = nil
    commentPopover = nil
    if let marker, let draft {
      // 打字全程只进草稿，关闭时一次性写回标注（每键直改 PDFAnnotation 是卡顿根因）。
      // 无编辑不触发写回：只是点开看一眼就关掉，不值得一次全量快照 + 落盘
      if draft.text != (marker.contents ?? "") {
        store.update(marker) { $0.contents = draft.text }
      }
      discardCommentIfEmpty(marker)
    }
    // 编辑框关闭 = 交互结束：把创建/输入期间攒下的重扫与写回排上
    store.resumeDeferredWrites()
  }
}

private extension NSView {
  /// 递归找第一个指定类型子视图
  func firstDescendant<T: NSView>(of type: T.Type) -> T? {
    for subview in subviews {
      if let match = subview as? T { return match }
      if let found = subview.firstDescendant(of: type) { return found }
    }
    return nil
  }
}

/// 不拦截点击的覆盖层（虚线框用）：事件穿透到下层
private final class PassthroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

/// 批注连接虚线层：内容边缘 → 卡片近边，随卡片布局动态重绘（不拦截事件）。
/// 取代旧实现（往 PDF 里塞几十个 1.1pt 点标注）——纯显示层，不进文件
final class CommentConnectorLayer: NSView {
  struct Segment {
    let start: NSPoint
    let end: NSPoint
    let color: NSColor
  }

  struct Frame {
    let rect: NSRect
    let color: NSColor
  }

  var segments: [Segment] = []
  /// 内容块虚线圆角框（视图坐标）：围住批注所指文本，与卡片同色系
  var frames: [Frame] = []

  override func draw(_ dirtyRect: NSRect) {
    for frame in frames {
      let path = NSBezierPath(roundedRect: frame.rect.insetBy(dx: -3, dy: -2), xRadius: 4, yRadius: 4)
      path.lineWidth = 1.5
      path.setLineDash([3, 2], count: 2, phase: 0)
      frame.color.withAlphaComponent(0.85).setStroke()
      path.stroke()
    }
    for segment in segments {
      let path = NSBezierPath()
      path.move(to: segment.start)
      path.line(to: segment.end)
      path.lineWidth = 1.5
      path.setLineDash([2, 3], count: 2, phase: 0)
      segment.color.withAlphaComponent(0.55).setStroke()
      path.stroke()
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

extension NSRect {
  /// 几何守卫：页→视图仿射变换可能产出 NaN/inf（选区 bounds 为 CGRect.null 的老坑，
  /// setFrame 遇非法几何直接 trap）——卡片与面板共用
  var isFiniteRect: Bool {
    [minX, minY, width, height].allSatisfy(\.isFinite)
  }
}
