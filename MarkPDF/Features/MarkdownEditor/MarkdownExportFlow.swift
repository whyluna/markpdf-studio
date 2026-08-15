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
      case .pdf: String(localized: "导出为 PDF")
      case .html: String(localized: "导出为 HTML")
      }
    }

    var fileExtension: String {
      switch self {
      case .pdf: "pdf"
      case .html: "html"
      }
    }
  }

  static func run(_ format: Format, store: EditorStore, workspaceRoot: URL? = nil) {
    // 独立离屏导出会话（与活体内核解耦）；文本/基准目录直接取自已同步的 EditorStore
    let session = MarkdownExportSession()
    session.exportHTML(
      text: store.text,
      baseURL: store.currentFileURL?.deletingLastPathComponent(),
      workspaceRoot: workspaceRoot
    ) { html, title in
      guard let html, !html.isEmpty else {
        alert(title: String(localized: "导出失败"), message: String(localized: "渲染结果为空或内核超时，请稍后再试。"))
        return
      }
      presentSavePanel(format: format, suggestedName: title ?? String(localized: "导出")) { url in
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
      alert(title: String(localized: "导出失败"), message: error.localizedDescription)
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
      MarkdownExportFlow.alert(title: String(localized: "导出失败"), message: error.localizedDescription)
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

  /// 页面加载完成：稍等图片等异步资源落定再打印
  private func finish() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self, let outputURL else { return }
      // NSPrintOperation 打印通道（Safari 同款）：A4 真实分页 + 遵循打印排版。
      // （WKWebView.createPDF 只是内容快照：整篇挤成一两页超长页，不做打印分页——已实测）
      let printInfo = NSPrintInfo()
      printInfo.paperSize = NSSize(width: 595, height: 842)  // A4（pt）
      printInfo.topMargin = 48
      printInfo.bottomMargin = 48
      printInfo.leftMargin = 48
      printInfo.rightMargin = 48
      printInfo.jobDisposition = .save
      (printInfo.dictionary() as NSMutableDictionary)[NSPrintInfo.AttributeKey.jobSavingURL] = outputURL
      let operation = webView.printOperation(with: printInfo)
      operation.showsPrintPanel = false
      operation.showsProgressPanel = false
      // AppKit 打印体系约定主线程使用：run() 内部是嵌套 runloop 模态执行，期间 UI 事件
      // 照常派发；后台线程跑依赖主线程 IPC 的 WebKit 打印是未定义行为区（不同系统/WebKit
      // 版本有空白页/死锁报告），宁可主线程模态也不赌后台
      let succeeded = operation.run()
      if succeeded, FileManager.default.fileExists(atPath: outputURL.path) {
        Logger.editor.info("已导出 PDF: \(outputURL.lastPathComponent, privacy: .public)")
      } else {
        MarkdownExportFlow.alert(title: String(localized: "导出失败"), message: String(localized: "PDF 打印任务未完成。"))
      }
      self.cleanup()
    }
  }

  private func fail(_ error: Error) {
    MarkdownExportFlow.alert(title: String(localized: "导出失败"), message: error.localizedDescription)
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
