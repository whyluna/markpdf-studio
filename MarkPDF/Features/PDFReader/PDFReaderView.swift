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
      guard let pdfView else { return }
      parent.pdfStore.scale = pdfView.scaleFactor
    }

    @objc func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
      guard let pdfView, recognizer.state == .changed else { return }
      pdfView.autoScales = false
      let newScale = PDFReaderStore.clamped(pdfView.scaleFactor * (1 + recognizer.magnification))
      pdfView.scaleFactor = newScale
      recognizer.magnification = 0
      parent.pdfStore.scale = newScale
    }
  }
}

#Preview {
  PDFReaderView(url: URL(fileURLWithPath: "/tmp/demo.pdf"))
    .environmentObject(PDFReaderStore())
    .frame(width: 640, height: 480)
}
