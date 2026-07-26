import AppKit
import WebKit
import os

/// 导出会话（FR-2.9）：每次导出创建一个离屏 WKWebView 加载内核，
/// 与活体内存编辑器完全解耦（此前经 EditorStore.kernel 反向引用活体内核，
/// 引用不可观测且生命周期受 SwiftUI 重建影响，导致「内核尚未就绪」）。
/// 成熟方案同构：Electron 隐藏 BrowserWindow + printToPDF（见 FR-2.9 调研记录）。
@MainActor
final class MarkdownExportSession {
  private let webView: WKWebView
  private let bridge = WebBridge()
  private var readyAction: (() -> Void)?

  /// 存活池：会话完成后必须 release（bridge handler 闭包自引用，需显式断链）
  private static var active: [ObjectIdentifier: MarkdownExportSession] = [:]

  init() {
    let configuration = WKWebViewConfiguration()
    // 内核为本地静态资源，非持久数据存储（与主编辑器一致）
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
    webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
    bridge.attach(to: webView)
  }

  /// 载入内核并就绪后执行 action
  private func start(_ action: @escaping () -> Void) {
    readyAction = action
    bridge.on(.ready) { [weak self] _, _ in
      Task { @MainActor in
        guard let self, let action = self.readyAction else { return }
        self.readyAction = nil
        action()
      }
    }
    guard let pageURL = Bundle.main.url(forResource: "index", withExtension: "html") else {
      Logger.editor.fault("缺少内核页面 index.html")
      return
    }
    var appPage = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
    // ?app=1：隐藏内核页面的开发调试工具栏（见 index.html）；lang：内核界面文案语言
    //（导出 fallback 标题等也走内核文案，与主编辑器一致注入）
    appPage?.query = "app=1&lang=\(SettingsStore.launchWebLocale)"
    webView.loadFileURL(appPage?.url ?? pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
  }

  /// 渲染导出 HTML（内核离屏 reading 模式重渲染）
  /// - Parameters:
  ///   - text: Markdown 全文（EditorStore 已同步）
  ///   - baseURL: 文档所在目录（图片相对路径解析）
  ///   - completion: (html, title)；失败为 (nil, nil)
  func exportHTML(text: String, baseURL: URL?, completion: @escaping (String?, String?) -> Void) {
    Self.retain(self)
    start { [weak self] in
      guard let self else { return }
      var payload: [String: Any] = ["text": text]
      if let baseURL {
        payload["baseURL"] = baseURL.absoluteString
      }
      bridge.notify(.setContent, payload: payload)
      bridge.notify(.setMode, payload: ["mode": "reading"])
      // 等内核落完内容与装饰（setContent 为同步 dispatch，短暂延迟即可）
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self else { return }
        bridge.request(.exportHTML) { [weak self] result in
          guard let self else { return }
          defer { Self.release(self) }
          if case .success(let payload) = result, let html = payload["html"] as? String, !html.isEmpty {
            completion(html, payload["title"] as? String)
          } else {
            completion(nil, nil)
          }
        }
      }
    }
  }

  // MARK: - 存活池

  private static func retain(_ session: MarkdownExportSession) {
    active[ObjectIdentifier(session)] = session
  }

  private static func release(_ session: MarkdownExportSession) {
    active.removeValue(forKey: ObjectIdentifier(session))
  }
}
