import AppKit
import SwiftUI
import WebKit
import os

/// Markdown 编辑器视图：WKWebView 内嵌 CodeMirror 6 内核（FR-2.1 / FR-2.2）。
/// 内核页面为 `Resources/Web/index.html`（bundle 根目录），脚本为 `dist/editor.js`。
struct MarkdownEditorView: NSViewRepresentable {
  /// 编辑模式（FR-2.2）
  enum EditorMode: String, CaseIterable, Identifiable {
    case wysiwyg
    case source
    case reading

    var id: String { rawValue }

    var title: String {
      switch self {
      case .wysiwyg: "所见即所得"
      case .source: "源码"
      case .reading: "阅读"
      }
    }
  }

  enum EditorTheme: String {
    case light, dark
  }

  /// 文档文本（绑定，供宿主读取/保存；外部改动请走 `Coordinator.loadDocument`）
  @Binding var text: String
  /// 外部文档标识（打开的文件 URL）：变化时内核整体载入 `text`；nil 表示欢迎页草稿
  let documentID: URL?
  let mode: EditorMode
  let theme: EditorTheme
  /// 请求内核滚动到指定行（FR-2.6 大纲跳转）；消费后经 `onScrollHandled` 清零
  let scrollToLine: Int?
  /// 载入文档时恢复的上次编辑行（FR-1.6 编辑位置记忆）；nil 不跳转
  let initialLine: Int?
  /// 工作区根目录（FR-2.5 图片存 assets/ 用）；nil = 无工作区
  let workspaceRoot: URL?
  /// 内核内容变更回调（自动保存挂钩，FR-2.7）
  var onContentChanged: ((String) -> Void)?
  /// 大纲变更回调（FR-2.6）
  var onOutlineChanged: (([Heading]) -> Void)?
  /// 滚动请求已消费回调
  var onScrollHandled: (() -> Void)?
  /// 光标行变化回调（FR-1.6；内核 500ms 防抖上报）
  var onCursorMoved: ((Int) -> Void)?

  init(
    text: Binding<String>,
    documentID: URL? = nil,
    mode: EditorMode = .wysiwyg,
    theme: EditorTheme = .light,
    scrollToLine: Int? = nil,
    initialLine: Int? = nil,
    workspaceRoot: URL? = nil,
    onContentChanged: ((String) -> Void)? = nil,
    onOutlineChanged: (([Heading]) -> Void)? = nil,
    onScrollHandled: (() -> Void)? = nil,
    onCursorMoved: ((Int) -> Void)? = nil
  ) {
    _text = text
    self.documentID = documentID
    self.mode = mode
    self.theme = theme
    self.scrollToLine = scrollToLine
    self.initialLine = initialLine
    self.workspaceRoot = workspaceRoot
    self.onContentChanged = onContentChanged
    self.onOutlineChanged = onOutlineChanged
    self.onScrollHandled = onScrollHandled
    self.onCursorMoved = onCursorMoved
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    // 内核为本地静态资源，无需持久化缓存；非持久数据存储避免旧 bundle 缓存干扰开发迭代
    configuration.websiteDataStore = .nonPersistent()
    // 图片内联显示（FR-2.3）：markpdf-file:// 协议由 native 读盘供给工作区图片
    configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: LocalFileSchemeHandler.scheme)
    let webView = WKWebView(frame: .zero, configuration: configuration)
    // 背景交给内核 CSS（明暗主题），避免白闪
    webView.setValue(false, forKey: "drawsBackground")

    let bridge = context.coordinator.bridge
    bridge.attach(to: webView)
    bridge.on(.ready) { [weak coordinator = context.coordinator] _, _ in
      // 桥接回调是非隔离闭包：跳到 MainActor 再触达 Coordinator（@MainActor）
      Task { @MainActor in
        coordinator?.kernelDidReady()
      }
    }
    bridge.on(.contentChanged) { [weak coordinator = context.coordinator] payload, _ in
      guard let text = payload["text"] as? String else { return }
      Task { @MainActor in
        coordinator?.contentDidChange(text)
      }
    }
    bridge.on(.outline) { [weak coordinator = context.coordinator] payload, _ in
      Task { @MainActor in
        coordinator?.outlineDidChange(payload)
      }
    }
    bridge.on(.cursor) { [weak coordinator = context.coordinator] payload, _ in
      guard let line = payload["line"] as? Int else { return }
      Task { @MainActor in
        coordinator?.parent.onCursorMoved?(line)
      }
    }
    // 粘贴/拖拽图片存盘（FR-2.5）：写入工作区 assets/，应答相对路径
    bridge.on(.saveImage) { [weak coordinator = context.coordinator] payload, id in
      guard let id else { return }
      Task { @MainActor in
        coordinator?.saveImage(payload: payload, id: id)
      }
    }
    // ⌘+点击链接：只允许 http/https 用默认浏览器打开（拦截 javascript:/file: 等协议）
    bridge.on(.openLink) { payload, _ in
      guard let urlString = payload["url"] as? String,
        let url = URL(string: urlString),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else { return }
      Task { @MainActor in
        NSWorkspace.shared.open(url)
      }
    }

    guard let pageURL = Bundle.main.url(forResource: "index", withExtension: "html") else {
      Logger.editor.fault("缺少内核页面 index.html（先执行 npm run build，并确认 Web/dist 已加入 target）")
      return webView
    }
    // ?app=1：隐藏内核页面的开发调试工具栏（见 index.html）
    var appPage = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
    appPage?.query = "app=1"
    webView.loadFileURL(appPage?.url ?? pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.parent = self
    // 外部文档切换（打开/切换文件）时整体载入；text 与 documentID 同源（EditorStore 同步更新）
    if context.coordinator.lastDocumentID != documentID {
      context.coordinator.lastDocumentID = documentID
      context.coordinator.loadDocument(text)
    }
    context.coordinator.pushModeAndThemeIfNeeded()
    // 大纲跳转请求（FR-2.6）：消费后异步清零（避免在视图更新途中改 @Published）
    if let line = scrollToLine {
      context.coordinator.scrollTo(line: line)
      DispatchQueue.main.async {
        self.onScrollHandled?()
      }
    }
  }
}

// MARK: - Coordinator

extension MarkdownEditorView {
  @MainActor
  final class Coordinator {
    var parent: MarkdownEditorView
    let bridge = WebBridge()
    /// markpdf-file 协议处理器（FR-2.3 图片供给）
    let schemeHandler = LocalFileSchemeHandler()

    private var isReady = false
    private var lastPushedMode: EditorMode?
    private var lastPushedTheme: EditorTheme?
    /// 图片资产存储（FR-2.5；可注入 mock 测试）
    let imageAssetService: ImageAssetService = LiveImageAssetService()
    /// 已载入内核的外部文档标识（去重，避免每次宿主刷新都重置内容）
    var lastDocumentID: URL?

    init(_ parent: MarkdownEditorView) {
      self.parent = parent
    }

    /// 内核加载完成：注入初始内容与当前模式/主题
    func kernelDidReady() {
      isReady = true
      bridge.notify(.setContent, payload: contentPayload(parent.text))
      lastDocumentID = parent.documentID
      lastPushedMode = nil
      lastPushedTheme = nil
      pushModeAndThemeIfNeeded()
    }

    /// setContent 载荷：文本 + 文档基准目录（图片相对路径解析，FR-2.3）+ 恢复编辑行（FR-1.6）
    private func contentPayload(_ text: String) -> [String: Any] {
      var payload: [String: Any] = ["text": text]
      if let baseURL = parent.documentID?.deletingLastPathComponent().absoluteString {
        payload["baseURL"] = baseURL
      }
      if let initialLine = parent.initialLine {
        payload["initialLine"] = initialLine
      }
      return payload
    }

    /// 将宿主的模式/主题同步给内核（去重，避免无效 JS 调用）
    func pushModeAndThemeIfNeeded() {
      guard isReady else { return }
      if lastPushedMode != parent.mode {
        bridge.notify(.setMode, payload: ["mode": parent.mode.rawValue])
        lastPushedMode = parent.mode
      }
      if lastPushedTheme != parent.theme {
        bridge.notify(.setTheme, payload: ["theme": parent.theme.rawValue])
        lastPushedTheme = parent.theme
      }
    }

    /// 内核内容变更：转发给宿主回调（自动保存挂钩，FR-2.7）
    func contentDidChange(_ text: String) {
      parent.onContentChanged?(text)
    }

    /// 内核大纲变更（FR-2.6）：解析后转发宿主
    func outlineDidChange(_ payload: [String: Any]) {
      let items = (payload["items"] as? [[String: Any]] ?? []).compactMap { dict -> Heading? in
        guard let level = dict["level"] as? Int,
          let text = dict["text"] as? String,
          let line = dict["line"] as? Int
        else { return nil }
        return Heading(level: level, text: text, line: line)
      }
      parent.onOutlineChanged?(items)
    }

    /// 大纲跳转（FR-2.6）：通知内核滚动到指定行
    func scrollTo(line: Int) {
      guard isReady else { return }
      bridge.notify(.scrollToLine, payload: ["line": line])
    }

    /// 外部载入新文档（打开文件时使用）；整体替换内容，不打断内核撤销栈之外的编辑
    func loadDocument(_ text: String) {
      guard isReady else { return }
      bridge.notify(.setContent, payload: contentPayload(text))
    }

    /// 从内核取回最新文本（保存快捷键等场景）
    func fetchContent(completion: @escaping (String) -> Void) {
      bridge.request(.getContent) { result in
        if case .success(let payload) = result, let text = payload["text"] as? String {
          completion(text)
        }
      }
    }

    /// 图片存盘请求（FR-2.5）：写工作区 assets/ 并应答相对路径；失败应答 error 并弹提示
    func saveImage(payload: [String: Any], id: String) {
      func fail(_ message: String) {
        bridge.respond(id: id, payload: ["error": message])
        let alert = NSAlert()
        alert.messageText = "图片保存失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
      }
      guard let dataString = payload["data"] as? String,
        let data = Data(base64Encoded: dataString)
      else {
        fail("图片数据解码失败。")
        return
      }
      guard let root = parent.workspaceRoot,
        let dir = parent.documentID?.deletingLastPathComponent()
      else {
        fail("草稿或未打开工作区时无法保存图片，请先保存文件。")
        return
      }
      do {
        let path = try imageAssetService.save(
          data: data,
          suggestedName: payload["name"] as? String,
          mime: payload["mime"] as? String,
          workspaceRoot: root,
          documentDir: dir
        )
        bridge.respond(id: id, payload: ["path": path])
      } catch {
        Logger.editor.error("图片存盘失败: \(error.localizedDescription, privacy: .public)")
        fail(error.localizedDescription)
      }
    }

    deinit {
      bridge.detach()
    }
  }
}

#Preview {
  MarkdownEditorView(text: .constant("# Hello\n\n**world**"), mode: .wysiwyg)
    .frame(width: 640, height: 480)
}
