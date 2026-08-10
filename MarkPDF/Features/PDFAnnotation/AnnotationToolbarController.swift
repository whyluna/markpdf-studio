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
  private let store: PDFAnnotationStore
  private let aiSettings: AISettingsStore
  private let translationStore: TranslationStore
  private var hostingView: NSHostingView<SelectionFloatingPanel>?
  private var mouseUpMonitor: Any?
  private var keyMonitor: Any?
  private var toolCancellable: AnyCancellable?
  private var translationCancellable: AnyCancellable?

  init(pdfView: PDFView, store: PDFAnnotationStore, aiSettings: AISettingsStore, aiKeys: AIKeyStore) {
    self.pdfView = pdfView
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
    pdfView.addSubview(hosting)
    hostingView = hosting

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(selectionChanged(_:)),
      name: .PDFViewSelectionChanged,
      object: pdfView
    )
    // 鼠标松开才弹出（划词途中不打扰）
    mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      self?.revealIfSelection(at: event)
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
    // 落在打字/点色那一瞬会卡住 UI；交互结束统一写（store.resumeDeferredWrites）
    store.isInteracting = { [weak self] in
      guard let self else { return false }
      return self.commentPopover != nil || self.deleteHosting?.isHidden == false
    }
    // Esc 退出激活的标注工具（FR-4.4）；不吞事件，查找栏等照常响应
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53, self?.store.activeTool != nil {
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
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let mouseUpMonitor {
      NSEvent.removeMonitor(mouseUpMonitor)
    }
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
    toolCancellable?.cancel()
    translationCancellable?.cancel()
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
    AnnotationKind.of(annotation) != nil || annotation.isCommentMarker
  }

  /// 把命中组改成指定色（FR-4.4）：逐个写回 + 重绘；编辑条留在原位以便连续试色
  private func recolorHits(to color: AnnotationColor) {
    guard let pdfView else { return }
    let targets = recolorableHits
    guard !targets.isEmpty else { return }
    for annotation in targets {
      store.update(annotation) { $0.color = color.nsColor }
    }
    pdfView.setNeedsDisplay(pdfView.bounds)
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
      pdfView.addSubview(border)
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
      pdfView.addSubview(hosting)
      deleteHosting = hosting
    }
    guard let deleteHosting else { return }
    let size = deleteHosting.fittingSize
    var origin = NSPoint(x: point.x + 8, y: point.y + 8)
    origin.x = min(max(origin.x, 4), pdfView.bounds.width - size.width - 4)
    origin.y = min(max(origin.y, 4), pdfView.bounds.height - size.height - 4)
    deleteHosting.frame = NSRect(origin: origin, size: size)
    deleteHosting.isHidden = false
    // 置顶：避免被虚线框覆盖导致点不到
    pdfView.addSubview(deleteHosting, positioned: .above, relativeTo: nil)
    syncCursorRects()
  }

  private func deleteHit() {
    guard let pdfView, let document = pdfView.document else { return }
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      for annotation in hitAnnotations where annotation.page === page {
        store.remove(annotation, from: page)
      }
    }
    pdfView.setNeedsDisplay(pdfView.bounds)
    hideDelete()
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
    y = avoidCommentCollision(x: x, y: y, size: size, on: page)
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
    store.add(marker, to: page)
    // PDFKit 添加 /Text 会自动补 Popup 伴侣：仅 shouldDisplay=false 仍参与命中测试，
    // PDFView 会给它画带手柄的原生选中框并吃掉那块区域的划词——直接从页面摘除
    if let popup = marker.popup {
      (popup as? PDFAnnotationPopup)?.isOpen = false
      popup.shouldDisplay = false
      page.removeAnnotation(popup)
    }

    // 点状虚线直线连接：内容块边缘 → 图标中心（排队错位时呈斜线，对应关系一目了然）
    let iconCenter = NSPoint(x: x + size / 2, y: y + size / 2)
    let anchorEdge = NSPoint(x: isLeft ? anchor.minX : anchor.maxX, y: anchor.midY)
    addDashedConnector(from: anchorEdge, to: iconCenter, color: palette, groupID: groupID, page: page)

    // 选中内容同步高亮（逐行，与 FR-4.1 高亮一致的贴合视觉）
    let highlighted = highlightLines(of: selection, color: palette, groupID: groupID)

    Logger.pdf.debug("添加批注[\(isLeft ? "左" : "右")边栏]: 页 \((pdfView.document?.index(for: page) ?? 0) + 1)，anchor=\(NSStringFromRect(anchor))，page=\(NSStringFromRect(pageBounds))，icon=\(NSStringFromRect(marker.bounds))，高亮 \(highlighted) 行")
    pdfView.setNeedsDisplay(pdfView.bounds)
    edit(comment: marker)
  }

  /// 逐行创建高亮（FR-4.1 视觉：上下各缩 14% 贴合文字，相邻行不叠块）
  @discardableResult
  private func highlightLines(of selection: PDFSelection, color: NSColor, groupID: String) -> Int {
    var created = 0
    for lineSelection in selection.selectionsByLine() {
      for page in lineSelection.pages {
        var bounds = lineSelection.bounds(for: page)
        guard !bounds.isNull, !bounds.isEmpty else { continue }
        let shrink = bounds.height * 0.14
        bounds = NSRect(
          x: bounds.minX,
          y: bounds.minY + shrink,
          width: bounds.width,
          height: bounds.height * 0.72
        )
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = color
        annotation.userName = groupID
        store.add(annotation, to: page)
        created += 1
      }
    }
    return created
  }

  /// 点状虚线：沿两点间直线（水平/垂直/斜线均可）按间距摆 1.1pt 小方块。
  /// PDFKit 不渲染程序化创建的 Line/Ink 标注（渲染探针实锤），高亮块是 PDFView 可渲染的最小单元
  private func addDashedConnector(from start: NSPoint, to end: NSPoint, color: NSColor, groupID: String, page: PDFPage) {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = hypot(dx, dy)
    guard length > Self.commentDashStep else { return }
    let dot = Self.commentDashSize
    var d: CGFloat = 0
    while d < length {
      let t = d / length
      let rect = NSRect(
        x: start.x + dx * t - dot / 2,
        y: start.y + dy * t - dot / 2,
        width: dot,
        height: dot
      )
      let dash = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
      dash.color = color
      dash.userName = groupID
      store.add(dash, to: page)
      d += Self.commentDashStep
    }
  }

  /// 与同页既有批注图标纵向避让（往下挪，最多 20 轮防极端堆叠死循环）
  private func avoidCommentCollision(x: CGFloat, y: CGFloat, size: CGFloat, on page: PDFPage) -> CGFloat {
    var rect = NSRect(x: x, y: y, width: size, height: size)
    for _ in 0..<20 {
      guard let collision = page.annotations.first(where: {
        $0.isCommentMarker && $0.bounds.intersects(rect)
      }) else { return rect.minY }
      rect.origin.y = collision.bounds.minY - size - 4
    }
    return rect.minY
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
    // 撤下创建时已排的落盘：否则那次写回正好砸在编辑框出现、光标该闪的时刻
    store.deferPendingWrites()
    commentPopover?.close()
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
    let anchorRect = pdfView.convert(marker.bounds, from: page)
    commentPopover = popover
    // 下一 runloop 再弹出：在 mouseDown/mouseUp 事件处理中同步 show 与 transient
    // 行为竞态，会导致编辑框偶发不出现
    DispatchQueue.main.async {
      popover.show(relativeTo: anchorRect, of: pdfView, preferredEdge: isLeft ? .maxX : .minX)
    }
  }

  /// 删除整条批注（图标 + 虚线段 + 高亮，同组；Popup 伴侣由 store.remove 连带）
  private func deleteComment(_ marker: PDFAnnotation) {
    guard let pdfView, let document = pdfView.document else { return }
    for annotation in groupAnnotations(matching: marker, in: document) {
      if let page = annotation.page {
        store.remove(annotation, from: page)
      }
    }
    editingComment = nil
    pdfView.setNeedsDisplay(pdfView.bounds)
    commentPopover?.close()
    commentPopover = nil
  }

  /// 编辑框关闭时仍为空 → 整条移除（避免残留空图标）
  private func discardCommentIfEmpty(_ marker: PDFAnnotation) {
    guard (marker.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let document = pdfView?.document
    else { return }
    for annotation in groupAnnotations(matching: marker, in: document) {
      if let page = annotation.page {
        store.remove(annotation, from: page)
      }
    }
    pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
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

  func popoverDidClose(_ notification: Notification) {
    // 先清引用再落盘：isInteracting 据此判定交互已结束，否则 update 只标脏不写
    let marker = editingComment
    let draft = commentDraft
    editingComment = nil
    commentDraft = nil
    commentPopover = nil
    if let marker, let draft {
      // 打字全程只进草稿，关闭时一次性写回标注（每键直改 PDFAnnotation 是卡顿根因）
      store.update(marker) { $0.contents = draft.text }
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
