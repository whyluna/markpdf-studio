import AppKit
import WebKit
import os

/// Markdown 导出流程（FR-2.9）：内核渲染独立 HTML → HTML 直接写盘 / 离屏 WKWebView 转 PDF。
/// 导出入口：工具栏导出菜单（对齐设计稿 #btnExport）与文件菜单。
@MainActor
enum MarkdownExportFlow {
  enum Format {
    case pdf
    case html

    var title: String {
      switch self {
      case .pdf: "导出为 PDF"
      case .html: "导出为 HTML"
      }
    }

    var fileExtension: String {
      switch self {
      case .pdf: "pdf"
      case .html: "html"
      }
    }
  }

  static func run(_ format: Format, store: EditorStore) {
    guard let kernel = store.kernel else {
      alert(title: "无法导出", message: "编辑器尚未就绪，请稍后再试。")
      return
    }
    kernel.requestExportHTML { html, title in
      guard let html, !html.isEmpty else {
        alert(title: "导出失败", message: "渲染结果为空或内核超时。")
        return
      }
      presentSavePanel(format: format, suggestedName: title ?? "导出") { url in
        switch format {
        case .html:
          writeHTML(html, to: url)
        case .pdf:
          MarkdownPDFGenerator().generate(
            html: html,
            inDirectory: store.currentFileURL?.deletingLastPathComponent(),
            to: url
          )
        }
      }
    }
  }

  // MARK: - 内部

  private static func presentSavePanel(format: Format, suggestedName: String, action: (URL) -> Void) {
    let panel = NSSavePanel()
    panel.title = format.title
    panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    action(url)
  }

  private static func writeHTML(_ html: String, to url: URL) {
    do {
      try html.write(to: url, atomically: true, encoding: .utf8)
      Logger.editor.info("已导出 HTML: \(url.lastPathComponent, privacy: .public)")
    } catch {
      Logger.editor.error("导出 HTML 失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      alert(title: "导出失败", message: error.localizedDescription)
    }
  }

  static func alert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
  }
}

/// 离屏 WKWebView 渲染导出的 HTML 并转 PDF（排版与编辑态渲染一致，FR-2.9 验收）。
/// 临时 HTML 写入 md 所在目录（隐藏文件，用完即删），相对图片路径因此可解析；
/// KaTeX CSS/字体走 app bundle 内绝对 file:// 路径（WebContent 进程可读 bundle）。
@MainActor
final class MarkdownPDFGenerator: NSObject, WKNavigationDelegate {
  private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
  private var tempFile: URL?
  private var outputURL: URL?

  /// 渲染并写出 PDF；失败弹提示。调用方无需持有本对象（自保持至完成）。
  func generate(html: String, inDirectory dir: URL?, to output: URL) {
    let dir = dir ?? FileManager.default.temporaryDirectory
    let temp = dir.appendingPathComponent(".markpdf-export-\(UUID().uuidString).html")
    do {
      try html.write(to: temp, atomically: true, encoding: .utf8)
    } catch {
      MarkdownExportFlow.alert(title: "导出失败", message: error.localizedDescription)
      return
    }
    tempFile = temp
    outputURL = output
    webView.navigationDelegate = self
    webView.loadFileURL(temp, allowingReadAccessTo: dir)
    // 自保持：delegate 引用链维持到完成
    MarkdownPDFGeneratorPool.retain(self)
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { @MainActor in
      finish()
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    Task { @MainActor in
      fail(error)
    }
  }

  nonisolated func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    Task { @MainActor in
      fail(error)
    }
  }

  /// 页面加载完成：稍等图片等异步资源落定再转 PDF
  private func finish() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self, let outputURL else { return }
      webView.createPDF(configuration: WKPDFConfiguration()) { result in
        switch result {
        case .success(let data):
          do {
            try data.write(to: outputURL, options: .atomic)
            Logger.editor.info("已导出 PDF: \(outputURL.lastPathComponent, privacy: .public)")
          } catch {
            MarkdownExportFlow.alert(title: "导出失败", message: error.localizedDescription)
          }
        case .failure(let error):
          MarkdownExportFlow.alert(title: "导出失败", message: error.localizedDescription)
        }
        self.cleanup()
      }
    }
  }

  private func fail(_ error: Error) {
    MarkdownExportFlow.alert(title: "导出失败", message: error.localizedDescription)
    cleanup()
  }

  private func cleanup() {
    if let tempFile {
      try? FileManager.default.removeItem(at: tempFile)
    }
    tempFile = nil
    outputURL = nil
    MarkdownPDFGeneratorPool.release(self)
  }
}

/// 生成器生命周期池（ delegate 链路外的显式自保持）
@MainActor
private enum MarkdownPDFGeneratorPool {
  private static var active: [ObjectIdentifier: MarkdownPDFGenerator] = [:]

  static func retain(_ generator: MarkdownPDFGenerator) {
    active[ObjectIdentifier(generator)] = generator
  }

  static func release(_ generator: MarkdownPDFGenerator) {
    active.removeValue(forKey: ObjectIdentifier(generator))
  }
}
