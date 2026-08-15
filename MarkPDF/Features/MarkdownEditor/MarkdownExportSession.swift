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
  private let schemeHandler = LocalFileSchemeHandler()
  private var readyAction: (() -> Void)?

  /// 存活池：会话完成后必须 release（bridge handler 闭包自引用，需显式断链）
  private static var active: [ObjectIdentifier: MarkdownExportSession] = [:]

  init() {
    let configuration = WKWebViewConfiguration()
    // 内核为本地静态资源，非持久数据存储（与主编辑器一致）
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(schemeHandler, forURLScheme: LocalFileSchemeHandler.scheme)
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
      // 快速失败：否则 ready 永不发出，只能靠看门狗 5s 后兜底
      finish(html: nil, title: nil)
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
  func exportHTML(text: String, baseURL: URL?, workspaceRoot: URL? = nil, completion: @escaping (String?, String?) -> Void) {
    Self.retain(self)
    completionHandler = completion
    // 与主编辑器同口径的路径围栏（工作区根 / 文档目录内可读）
    schemeHandler.allowedRoots = {
      [workspaceRoot, baseURL].compactMap { $0 }
    }
    // 就绪看门狗：内核页面缺失/加载失败/JS 异常导致 ready 永不发出时，
    // completion 永不被调且会话永久滞留存活池（连同 webView 一并泄漏）——
    // 5s 兜底按失败完成并释放（bridge 的 3s 超时只保护 ready 之后的阶段）
    let watchdog = DispatchWorkItem { [weak self] in
      self?.finish(html: nil, title: nil)
    }
    readyWatchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: watchdog)
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
          if case .success(let payload) = result, let html = payload["html"] as? String, !html.isEmpty {
            self.finish(html: html, title: payload["title"] as? String)
          } else {
            self.finish(html: nil, title: nil)
          }
        }
      }
    }
  }

  // MARK: - 存活池

  /// 一次性完成通道：取消看门狗、回调、释放存活池（多路径并发也只完成一次）
  private func finish(html: String?, title: String?) {
    guard !didFinish else { return }
    didFinish = true
    readyWatchdog?.cancel()
    readyWatchdog = nil
    completionHandler?(html, title)
    completionHandler = nil
    Self.release(self)
  }

  private var completionHandler: ((String?, String?) -> Void)?
  private var readyWatchdog: DispatchWorkItem?
  private var didFinish = false

  private static func retain(_ session: MarkdownExportSession) {
    active[ObjectIdentifier(session)] = session
  }

  private static func release(_ session: MarkdownExportSession) {
    active.removeValue(forKey: ObjectIdentifier(session))
  }
}
