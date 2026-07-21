import AppKit
import PDFKit
import os

/// 复制为带回链的引用块（FR-5.2）：引用块 + 页码回链（相对工作区根目录路径，FR-5.3 可解析）。
/// 供菜单命令（MarkPDFApp）与命令面板（ContentView）共用。
enum PDFQuoteExporter {
  @MainActor
  static func copyAsQuote(pdfView: PDFView?, currentPage: Int, workspaceRoot: URL?) {
    guard let pdfView,
      let selection = pdfView.currentSelection,
      let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty,
      let pdfURL = pdfView.document?.documentURL
    else { return }
    let page = (selection.pages.first.flatMap { pdfView.document?.index(for: $0) } ?? (currentPage - 1)) + 1
    // 相对工作区根目录的路径（任何 md 都能经根目录回退解析）；无工作区退化为文件名
    let relPath = workspaceRoot.map {
      MarkdownImageLinkRewriter.relativePath(from: $0, to: pdfURL)
    } ?? pdfURL.lastPathComponent
    let quoted = text.components(separatedBy: .newlines)
      .map { $0.isEmpty ? ">" : "> \($0)" }
      .joined(separator: "\n")
    let name = pdfURL.deletingPathExtension().lastPathComponent
    let quote = "\(quoted)\n>\n> — [\(name) · p.\(page)](\(relPath)#page=\(page))"
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(quote, forType: .string)
    Logger.pdf.debug("已复制回链引用: \(pdfURL.lastPathComponent, privacy: .public) p.\(page)")
  }
}
