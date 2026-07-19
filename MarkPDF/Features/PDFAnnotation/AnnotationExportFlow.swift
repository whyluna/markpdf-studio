import AppKit
import PDFKit
import UniformTypeIdentifiers
import os

/// 标注导出流程（FR-4.8）：选目标笔记 → 合并去重 → 原子写盘。
/// 成功（含"无新增"情形）返回目标笔记 URL 供宿主打开；用户取消或失败返回 nil。
@MainActor
enum AnnotationExportFlow {
  static func run(store: PDFAnnotationStore) -> URL? {
    guard let pdfURL = store.currentFileURL else { return nil }
    let lines = AnnotationMarkdownExporter.lines(for: store.annotationItems())
    let pdfBaseName = pdfURL.deletingPathExtension().lastPathComponent
    guard !lines.isEmpty else {
      alert(title: "没有可导出的标注", message: "当前 PDF 还没有任何标注。")
      return nil
    }

    let panel = NSSavePanel()
    panel.title = "导出全部标注为 Markdown"
    panel.nameFieldStringValue = "\(pdfBaseName)-标注.md"
    panel.directoryURL = pdfURL.deletingLastPathComponent()
    if let mdType = UTType(filenameExtension: "md") {
      panel.allowedContentTypes = [mdType]
    }
    guard panel.runModal() == .OK, let target = panel.url else { return nil }

    let existing = try? String(contentsOf: target, encoding: .utf8)
    let (content, addedCount) = AnnotationMarkdownExporter.mergedContent(
      existing: existing, pdfBaseName: pdfBaseName, newLines: lines)
    guard addedCount > 0 else {
      alert(title: "没有新标注", message: "全部 \(lines.count) 条标注已存在于目标笔记中。")
      return target
    }
    do {
      // 原子写盘：先写临时文件再替换（开发规范 §10）
      try content.write(to: target, atomically: true, encoding: .utf8)
      Logger.pdf.info("已导出 \(addedCount) 条标注到: \(target.lastPathComponent, privacy: .public)")
      return target
    } catch {
      Logger.pdf.error("导出标注失败 \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      alert(title: "导出失败", message: error.localizedDescription)
      return nil
    }
  }

  private static func alert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.runModal()
  }
}
