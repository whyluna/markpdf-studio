import PDFKit
import SwiftUI

/// PDF 阅读视图（FR-3.1/3.2）：系统 PDFKit 渲染，连续滚动；
/// 缩放支持按钮/快捷键（Store 驱动）与触控板捏合，范围 50%–400%。
/// 高亮 / 下划线等标注能力（FR-4.x）将在 M2 叠加在此视图之上。
struct PDFReaderView: NSViewRepresentable {
  let url: URL
  @EnvironmentObject private var pdfStore: PDFReaderStore

  func makeNSView(context: Context) -> PDFView {
    let pdfView = PDFView()
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.autoScales = true
    pdfView.document = PDFDocument(url: url)

    // 触控板捏合缩放（FR-3.2）
    let pinch = NSMagnificationGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handlePinch(_:))
    )
    pdfView.addGestureRecognizer(pinch)

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
    return pdfView
  }

  func updateNSView(_ pdfView: PDFView, context: Context) {
    if pdfView.document?.documentURL != url {
      pdfView.document = PDFDocument(url: url)
      // 新文档回到自适应宽度
      pdfView.autoScales = true
      context.coordinator.syncPageState()
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
  final class Coordinator {
    var parent: PDFReaderView
    weak var pdfView: PDFView?
    /// 捏合手势进行中（此时不回写 Store，避免逐帧触发 SwiftUI 重渲染）
    private var isPinching = false
    /// 手势期间临时收起的文本选区（结束后恢复）
    private var savedSelection: PDFSelection?
    /// 手势起始缩放倍率
    private var pinchStartScale: CGFloat = 1
    /// 手势累计放大倍率
    private var pinchTotalMagnification: CGFloat = 1

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

    @objc func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
      guard let pdfView else { return }
      switch recognizer.state {
      case .began:
        isPinching = true
        pinchStartScale = pdfView.scaleFactor
        pinchTotalMagnification = 1
        pdfView.wantsLayer = true
        // 手势期间临时收起文本选区：PDFView 会围绕选区反复滚动（乱跳根因）
        savedSelection = pdfView.currentSelection
        if savedSelection != nil {
          pdfView.setCurrentSelection(nil, animate: false)
        }
      case .changed:
        pinchTotalMagnification *= (1 + recognizer.magnification)
        recognizer.magnification = 0
        // 手势期间只做 GPU 图层缩放（流畅），不做昂贵的逐帧重排版；视觉比例同样夹取在 50%–400%
        let target = PDFReaderStore.clamped(pinchStartScale * pinchTotalMagnification)
        let ratio = target / pinchStartScale
        pdfView.layer?.transform = CATransform3DMakeScale(ratio, ratio, 1)
      case .ended, .cancelled:
        isPinching = false
        let target = PDFReaderStore.clamped(pinchStartScale * pinchTotalMagnification)
        // 同一 runloop 内先清图层变换再应用真实缩放，一次性重排，避免双重缩放帧
        pdfView.layer?.transform = CATransform3DIdentity
        if pdfView.autoScales { pdfView.autoScales = false }
        pdfView.scaleFactor = target
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
