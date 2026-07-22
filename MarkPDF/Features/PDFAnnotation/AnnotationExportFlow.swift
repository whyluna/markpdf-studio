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
    let items = store.annotationItems()
    let pdfBaseName = pdfURL.deletingPathExtension().lastPathComponent
    guard !items.isEmpty else {
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

    // 页码回链：相对目标笔记目录的路径（FR-5.3 可解析；点击跳回 PDF 对应页）
    let pdfRelative = MarkdownImageLinkRewriter.relativePath(
      from: target.deletingLastPathComponent(), to: pdfURL)
    let lines = AnnotationMarkdownExporter.lines(for: items) { page in
      "\(pdfRelative)#page=\(page)"
    }
    let existing: String?
    do {
      existing = try Self.readExistingContent(at: target)
    } catch {
      // 文件存在但读不出（如 UTF-16 编码）：必须中止——按「不存在」走全新分支
      // 会整体覆盖原文件，造成数据丢失（Bug C2）
      Logger.pdf.error("导出标注失败：目标文件读取失败 \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      alert(title: "导出失败", message: "目标文件已存在但无法读取，已中止导出以避免覆盖原内容：\(error.localizedDescription)")
      return nil
    }
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

  /// 读取导出目标既有内容：文件不存在返回 nil（走全新写入）；
  /// 存在但读取失败（如非 UTF-8 编码）抛错，由调用方中止导出——
  /// 两者混同会把既有文件当新文件整体覆盖（Bug C2 数据丢失根因）
  nonisolated static func readExistingContent(at target: URL) throws -> String? {
    guard FileManager.default.fileExists(atPath: target.path) else { return nil }
    return try String(contentsOf: target, encoding: .utf8)
  }

  private static func alert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.runModal()
  }
}
