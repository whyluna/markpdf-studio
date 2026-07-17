import PDFKit
import SwiftUI

/// PDF 阅读视图（FR-3.1 最小可用版）：系统 PDFKit 渲染，连续滚动 + 自适应缩放。
/// 高亮 / 下划线等标注能力（FR-4.x）将在 M2 叠加在此视图之上。
struct PDFReaderView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> PDFView {
    let pdfView = PDFView()
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.document = PDFDocument(url: url)
    return pdfView
  }

  func updateNSView(_ pdfView: PDFView, context: Context) {
    guard pdfView.document?.documentURL != url else { return }
    pdfView.document = PDFDocument(url: url)
  }
}

#Preview {
  PDFReaderView(url: URL(fileURLWithPath: "/tmp/demo.pdf"))
    .frame(width: 640, height: 480)
}
