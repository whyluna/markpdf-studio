import os
import PDFKit
import SwiftUI

/// 划词浮动工具条控制器（FR-4.1）：
/// 监听 PDFView 选区变化，鼠标松开后在选区上方弹出工具条；
/// 动作时把选区转为对应文本标注（逐页创建，PDFKit 自动按文本基线分段）。
@MainActor
final class AnnotationToolbarController: NSObject {
  private weak var pdfView: PDFView?
  private let store: PDFAnnotationStore
  private var hostingView: NSHostingView<FloatingToolbarView>?
  private var mouseUpMonitor: Any?

  init(pdfView: PDFView, store: PDFAnnotationStore) {
    self.pdfView = pdfView
    self.store = store
    super.init()

    let toolbar = FloatingToolbarView(colorsByKind: store.colorsByKind) { [weak self] kind in
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
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let mouseUpMonitor {
      NSEvent.removeMonitor(mouseUpMonitor)
    }
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
  }

  private func hide() {
    hostingView?.isHidden = true
  }

  // MARK: - 标注动作

  private func apply(kind: AnnotationKind) {
    guard let pdfView, let selection = pdfView.currentSelection else { return }
    let subtype: PDFAnnotationSubtype
    switch kind {
    case .highlight: subtype = .highlight
    case .underline: subtype = .underline
    case .strikeOut: subtype = .strikeOut
    case .squiggly:
      // Swift 枚举无 squiggly 成员，按 PDF 规范 rawValue 构造
      subtype = PDFAnnotationSubtype(rawValue: "/Squiggly")
    default: return
    }
    let color = store.colorsByKind[kind]?.nsColor ?? .yellow
    var created = 0
    for page in selection.pages {
      let bounds = selection.bounds(for: page)
      guard !bounds.isNull, !bounds.isEmpty else { continue }
      let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
      annotation.color = color
      store.add(annotation, to: page)
      created += 1
    }
    if created > 0 {
      Logger.pdf.debug("添加文本标注[\(kind.rawValue)]: \(created) 页")
    }
    pdfView.clearSelection()
    hide()
  }
}
