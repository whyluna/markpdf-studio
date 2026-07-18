import Combine
import os
import PDFKit
import SwiftUI

/// 划词浮动工具条控制器（FR-4.1）：
/// 监听 PDFView 选区变化，鼠标松开后在选区上方弹出工具条；
/// 动作时把选区转为对应文本标注（逐行创建，精确贴合选中文字）。
/// 另支持点击既有标注 → 弹出删除按钮（点选即删）。
@MainActor
final class AnnotationToolbarController: NSObject {
  private weak var pdfView: PDFView?
  private let store: PDFAnnotationStore
  private var hostingView: NSHostingView<FloatingToolbarView>?
  private var mouseUpMonitor: Any?
  private var keyMonitor: Any?
  private var toolCancellable: AnyCancellable?

  init(pdfView: PDFView, store: PDFAnnotationStore) {
    self.pdfView = pdfView
    self.store = store
    super.init()

    let toolbar = FloatingToolbarView(store: store) { [weak self] kind in
      self?.apply(kind: kind)
    }
    let hosting = NSHostingView(rootView: toolbar)
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
      self?.revealIfSelection()
      return event
    }
    // 点击既有标注 → 点选删除
    let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
    click.delaysPrimaryMouseButtonEvents = false
    pdfView.addGestureRecognizer(click)
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
  }

  // MARK: - 弹出与隐藏

  @objc private func selectionChanged(_ note: Notification) {
    guard let pdfView else { return }
    if pdfView.currentSelection == nil {
      hide()
    }
  }

  private func revealIfSelection() {
    guard let pdfView, let selection = pdfView.currentSelection, !selection.pages.isEmpty else {
      hide()
      return
    }
    // 工具栏标注工具激活中（FR-4.4）：划词即标，不再弹出浮动工具条
    if let tool = store.activeTool {
      apply(kind: tool)
      return
    }
    show(above: selection)
  }

  private func show(above selection: PDFSelection) {
    guard let pdfView, let hostingView,
      let page = selection.pages.last
    else { return }
    let pageBounds = selection.bounds(for: page)
    let viewBounds = pdfView.convert(pageBounds, from: page)
    let size = hostingView.fittingSize
    // 选区上方居中，并夹取在视图范围内
    var origin = NSPoint(
      x: viewBounds.midX - size.width / 2,
      y: viewBounds.maxY + 8
    )
    origin.x = min(max(origin.x, 8), pdfView.bounds.width - size.width - 8)
    if origin.y + size.height > pdfView.bounds.height - 8 {
      // 上方放不下则放选区下方
      origin.y = viewBounds.minY - size.height - 8
    }
    hostingView.frame = NSRect(origin: origin, size: size)
    hostingView.isHidden = false
    syncCursorRects()
  }

  private func hide() {
    hostingView?.isHidden = true
    syncCursorRects()
  }

  /// 把可见浮动层的 frame 同步给 ZoomablePDFView 的手型光标区域
  private func syncCursorRects() {
    guard let zoomable = pdfView as? ZoomablePDFView else { return }
    var rects: [CGRect] = []
    if let hostingView, !hostingView.isHidden {
      rects.append(hostingView.frame)
    }
    if let deleteHosting, !deleteHosting.isHidden {
      rects.append(deleteHosting.frame)
    }
    zoomable.handCursorRects = rects
  }

  // MARK: - 标注动作

  private func apply(kind: AnnotationKind) {
    guard let pdfView, let selection = pdfView.currentSelection else { return }
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
  /// 删除按钮（光标旁）
  private var deleteHosting: NSHostingView<DeleteButtonView>?

  @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
    guard let pdfView, recognizer.state == .ended else { return }
    let point = recognizer.location(in: pdfView)
    // 点击落在删除按钮上：交给按钮自身处理，不再走标注命中（否则会点到按钮背后的标注）
    if let deleteHosting, !deleteHosting.isHidden, deleteHosting.frame.contains(point) {
      return
    }
    // 任意点击先收起（空白处点击即消失）
    hideDelete()
    guard let page = pdfView.page(for: point, nearest: false),
      let document = pdfView.document
    else { return }
    let pagePoint = pdfView.convert(point, to: page)
    guard let annotation = page.annotation(at: pagePoint) else { return }
    // 整体：同组 ID 的标注一起框选、一起删除
    hitAnnotations = groupAnnotations(matching: annotation, in: document)
    showDashedBorders(around: hitAnnotations)
    showDeleteButton(at: point)
  }

  /// 按组 ID 收集同组标注（无组 ID 的单标注返回自身）
  private func groupAnnotations(matching annotation: PDFAnnotation, in document: PDFDocument) -> [PDFAnnotation] {
    guard let groupID = annotation.userName, !groupID.isEmpty else { return [annotation] }
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

  /// 删除按钮出现在光标旁（夹取在视图内；置顶于虚线框之上）
  private func showDeleteButton(at point: NSPoint) {
    guard let pdfView else { return }
    if deleteHosting == nil {
      let hosting = NSHostingView(rootView: DeleteButtonView { [weak self] in
        self?.deleteHit()
      })
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
  }
}

/// 不拦截点击的覆盖层（虚线框用）：事件穿透到下层
private final class PassthroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
