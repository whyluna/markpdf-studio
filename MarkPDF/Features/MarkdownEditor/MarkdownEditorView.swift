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
      case .wysiwyg: String(localized: "所见即所得")
      case .source: String(localized: "源码")
      case .reading: String(localized: "阅读")
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
  /// 内核命令队列（FR-AI.2 编辑器动作）；消费后经 `onKernelRequestsHandled` 清空
  let kernelRequests: [EditorStore.KernelRequest]
  /// 载入文档时恢复的上次编辑行（FR-1.6 编辑位置记忆）；nil 不跳转
  let initialLine: Int?
  /// 工作区根目录（FR-2.5 图片存 assets/ 用）；nil = 无工作区
  let workspaceRoot: URL?
  /// 编辑器排版（FR-7.2）：字体 CSS 栈（空串 = 内核默认）、字号、行高
  let fontCSS: String
  let fontSize: Double
  let lineHeight: Double
  /// 段距（美化第二阶段）：块间空行行高系数
  let paraGap: Double
  /// 打字机/专注模式（FR-2.10）
  let typewriter: Bool
  let focusMode: Bool
  /// 内核内容变更回调（自动保存挂钩，FR-2.7）
  var onContentChanged: ((String) -> Void)?
  /// 大纲变更回调（FR-2.6）
  var onOutlineChanged: (([Heading]) -> Void)?
  /// 滚动请求已消费回调
  var onScrollHandled: (() -> Void)?
  /// 内核命令队列已消费回调
  var onKernelRequestsHandled: (() -> Void)?
  /// 活体内核视图挂载/拆除回调（AI 动作的无活体兜底，防回调型请求悬挂）
  var onKernelConsumerChanged: ((Bool) -> Void)?
  /// 光标行变化回调（FR-1.6；内核 500ms 防抖上报）
  var onCursorMoved: ((Int) -> Void)?
  /// 文件回链打开回调（FR-5.3；参数为解析后的文件 URL 与可选页码）
  var onOpenFileLink: ((URL, Int?) -> Void)?

  init(
    text: Binding<String>,
    documentID: URL? = nil,
    mode: EditorMode = .wysiwyg,
    theme: EditorTheme = .light,
    scrollToLine: Int? = nil,
    kernelRequests: [EditorStore.KernelRequest] = [],
    initialLine: Int? = nil,
    workspaceRoot: URL? = nil,
    fontCSS: String = "",
    fontSize: Double = SettingsStore.defaultFontSize,
    lineHeight: Double = SettingsStore.defaultLineHeight,
    paraGap: Double = SettingsStore.defaultParaGap,
    typewriter: Bool = false,
    focusMode: Bool = false,
    onContentChanged: ((String) -> Void)? = nil,
    onOutlineChanged: (([Heading]) -> Void)? = nil,
    onScrollHandled: (() -> Void)? = nil,
    onKernelRequestsHandled: (() -> Void)? = nil,
    onKernelConsumerChanged: ((Bool) -> Void)? = nil,
    onCursorMoved: ((Int) -> Void)? = nil,
    onOpenFileLink: ((URL, Int?) -> Void)? = nil
  ) {
    _text = text
    self.documentID = documentID
    self.mode = mode
    self.theme = theme
    self.scrollToLine = scrollToLine
    self.kernelRequests = kernelRequests
    self.initialLine = initialLine
    self.workspaceRoot = workspaceRoot
    self.fontCSS = fontCSS
    self.fontSize = fontSize
    self.lineHeight = lineHeight
    self.paraGap = paraGap
    self.typewriter = typewriter
    self.focusMode = focusMode
    self.onContentChanged = onContentChanged
    self.onOutlineChanged = onOutlineChanged
    self.onScrollHandled = onScrollHandled
    self.onKernelRequestsHandled = onKernelRequestsHandled
    self.onKernelConsumerChanged = onKernelConsumerChanged
    self.onCursorMoved = onCursorMoved
    self.onOpenFileLink = onOpenFileLink
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> WKWebView {
    // 活体消费者就位（dismantle 时对称置 false）
    onKernelConsumerChanged?(true)
    let configuration = WKWebViewConfiguration()
    // 内核为本地静态资源，无需持久化缓存；非持久数据存储避免旧 bundle 缓存干扰开发迭代
    configuration.websiteDataStore = .nonPersistent()
    // 图片内联显示（FR-2.3）：markpdf-file:// 协议由 native 读盘供给工作区图片。
    // 路径围栏：仅工作区根与当前文档目录内可读（parent 每轮跟随，根随宿主更新）
    context.coordinator.schemeHandler.allowedRoots = { [weak coordinator = context.coordinator] in
      guard let parent = coordinator?.parent else { return [] }
      var roots: [URL] = []
      if let root = parent.workspaceRoot { roots.append(root) }
      if let dir = parent.documentID?.deletingLastPathComponent() { roots.append(dir) }
      // mermaid 懒加载脚本经本协议供给（P1-4）：file:// 页面动态 <script> 加载本地
      // 资源被 WebKit 拦截，白名单精确到这一个文件
      if let mmd = Bundle.main.url(forResource: "mermaid-render", withExtension: "js", subdirectory: "dist") {
        roots.append(mmd)
      }
      return roots
    }
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
    // ⌘+点击链接：http/https 用默认浏览器打开；文件回链（FR-5.3）解析后打开标签
    bridge.on(.openLink) { [weak coordinator = context.coordinator] payload, _ in
      guard let urlString = payload["url"] as? String else { return }
      Task { @MainActor in
        coordinator?.openLink(urlString)
      }
    }

    guard let pageURL = Bundle.main.url(forResource: "index", withExtension: "html") else {
      Logger.editor.fault("缺少内核页面 index.html（先执行 npm run build，并确认 Web/dist 已加入 target）")
      return webView
    }
    // ?app=1：隐藏内核页面的开发调试工具栏（见 index.html）；lang：内核界面文案语言；
    // mmd：mermaid 懒加载脚本经 markpdf-file:// 协议供给的地址（file:// 动态 script 被拦，P1-4）
    var appPage = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
    var queryItems = [
      URLQueryItem(name: "app", value: "1"),
      URLQueryItem(name: "lang", value: SettingsStore.launchWebLocale),
    ]
    if let mmd = Bundle.main.url(forResource: "mermaid-render", withExtension: "js", subdirectory: "dist") {
      var comps = URLComponents()
      comps.scheme = LocalFileSchemeHandler.scheme
      comps.path = mmd.path
      queryItems.append(URLQueryItem(name: "mmd", value: comps.url?.absoluteString))
    }
    appPage?.queryItems = queryItems
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
    // 内核命令队列（FR-AI.2 编辑器动作）：逐条派发后异步清空
    if !kernelRequests.isEmpty {
      for request in kernelRequests {
        context.coordinator.perform(request)
      }
      DispatchQueue.main.async {
        self.onKernelRequestsHandled?()
      }
    }
  }

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    // 先告知宿主「无活体消费者」：队列里未消费的回调型请求立即失败回调，不悬挂调用方
    coordinator.parent.onKernelConsumerChanged?(false)
    // 销毁前兜底取回内核全文（FR-2.7）：内核 300ms 防抖窗口内未上报的尾巴，
    // 取回后与宿主文本比对，不同则以内核为准走正常 contentDidChange（含自动保存）
    coordinator.fetchContentBeforeDismantle(retaining: nsView)
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
    /// 排版去重键（FR-7.2/2.10）
    struct Typography: Equatable {
      var fontCSS: String
      var fontSize: Double
      var lineHeight: Double
      var paraGap: Double
      var typewriter: Bool
      var focusMode: Bool
    }
    private var lastPushedTypography: Typography?
    /// 内核就绪前排队的滚动行（scrollTo 在就绪前调用不再丢弃，FR-6.2 跳转依赖）
    private var pendingKernelScrollLine: Int?
    /// 内核就绪前排队的插入文本（insertAtCursor 无回调，就绪前丢弃会让 AI 插入动作无声消失）
    private var pendingInserts: [String] = []
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
      lastPushedTypography = nil
      pushModeAndThemeIfNeeded()
      // 就绪前排队的滚动请求（全文搜索跳转等）补发
      if let line = pendingKernelScrollLine {
        pendingKernelScrollLine = nil
        bridge.notify(.scrollToLine, payload: ["line": line])
      }
      // 就绪前排队的插入请求补发（须在 setContent 之后，插进新内容）
      if !pendingInserts.isEmpty {
        for text in pendingInserts {
          bridge.notify(.insertAtCursor, payload: ["text": text])
        }
        pendingInserts = []
      }
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
      // FR-7.2：排版（字号/行高/段距/字体任一变化即推送）；FR-2.10：打字机/专注模式
      let typography = Typography(
        fontCSS: parent.fontCSS,
        fontSize: parent.fontSize,
        lineHeight: parent.lineHeight,
        paraGap: parent.paraGap,
        typewriter: parent.typewriter,
        focusMode: parent.focusMode
      )
      if lastPushedTypography != typography {
        Logger.editor.debug("推送排版: tw=\(typography.typewriter), focus=\(typography.focusMode)")
        bridge.notify(.setTypography, payload: [
          "fontCSS": typography.fontCSS,
          "fontSize": typography.fontSize,
          "lineHeight": typography.lineHeight,
          "paraGap": typography.paraGap,
        ])
        bridge.notify(.setTypewriter, payload: ["enabled": typography.typewriter])
        bridge.notify(.setFocusMode, payload: ["enabled": typography.focusMode])
        lastPushedTypography = typography
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

    /// 大纲跳转（FR-2.6）：通知内核滚动到指定行；内核未就绪则排队，就绪后补发
    func scrollTo(line: Int) {
      guard isReady else {
        pendingKernelScrollLine = line
        return
      }
      bridge.notify(.scrollToLine, payload: ["line": line])
    }

    /// 内核命令（FR-AI.2 编辑器动作）：失败/超时/未就绪必回调（不静默悬挂）
    func perform(_ request: EditorStore.KernelRequest) {
      switch request {
      case .insertAtCursor(let text):
        guard isReady else {
          pendingInserts.append(text)
          return
        }
        bridge.notify(.insertAtCursor, payload: ["text": text])
      case .replaceSelection(let text, let completion):
        guard isReady else { return completion(false) }
        bridge.request(.replaceSelection, payload: ["text": text]) { result in
          let replaced = (try? result.get())?["replaced"] as? Bool ?? false
          Task { @MainActor in completion(replaced) }
        }
      case .fetchSelection(let completion):
        guard isReady else { return completion(nil) }
        bridge.request(.getSelection) { result in
          let text = (try? result.get())?["text"] as? String
          Task { @MainActor in completion(text) }
        }
      }
    }

    /// 外部载入新文档（打开文件时使用）；整体替换内容并重置内核撤销栈（换档即重置，防跨档 ⌘Z 串档）
    func loadDocument(_ text: String) {
      guard isReady else { return }
      bridge.notify(.setContent, payload: contentPayload(text))
    }

    /// 从内核取回最新文本（视图销毁前兜底取回用）。
    /// 失败/异常载荷也回调（nil）：调用方在回调里收口 webView 强引用，失败路径不得静默悬挂
    func fetchContent(completion: @escaping (String?) -> Void) {
      bridge.request(.getContent) { result in
        guard case .success(let payload) = result, let text = payload["text"] as? String else {
          completion(nil)
          return
        }
        completion(text)
      }
    }

    /// 视图销毁前兜底取回内核全文（防抖窗口内未上报的尾巴，FR-2.7）。
    /// 请求往返期间强引用 webView：dismantle 返回后若无强引用，JS 求值会随销毁被丢弃
    func fetchContentBeforeDismantle(retaining webView: WKWebView) {
      guard isReady else { return }
      let baseline = parent.text
      fetchContent { [weak self] fetched in
        withExtendedLifetime(webView) {}
        Task { @MainActor [weak self] in
          // 取回失败（nil）或与宿主一致：无需回写
          guard let self, let fetched, fetched != baseline else { return }
          self.parent.onContentChanged?(fetched)
        }
      }
    }

    /// ⌘+点击链接（FR-2.3 / FR-5.3）：http/https 走浏览器；文件回链解析后交给宿主打开
    func openLink(_ urlString: String) {
      if let url = URL(string: urlString),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      {
        NSWorkspace.shared.open(url)
        return
      }
      guard let link = MarkdownFileLink.parse(urlString),
        let target = MarkdownFileLink.resolve(
          path: link.path,
          documentDir: parent.documentID?.deletingLastPathComponent(),
          workspaceRoot: parent.workspaceRoot
        )
      else { return }
      Logger.editor.debug("回链跳转: \(target.lastPathComponent, privacy: .public) page=\(link.page ?? -1)")
      parent.onOpenFileLink?(target, link.page)
    }

    /// 图片存盘请求（FR-2.5）：写工作区 assets/ 并应答相对路径；失败应答 error 并弹提示
    func saveImage(payload: [String: Any], id: String) {
      func fail(_ message: String) {
        bridge.respond(id: id, payload: ["error": message])
        let alert = NSAlert()
        alert.messageText = String(localized: "图片保存失败")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
      }
      guard let dataString = payload["data"] as? String,
        let data = Data(base64Encoded: dataString)
      else {
        fail(String(localized: "图片数据解码失败。"))
        return
      }
      guard let root = parent.workspaceRoot,
        let dir = parent.documentID?.deletingLastPathComponent()
      else {
        fail(String(localized: "草稿或未打开工作区时无法保存图片，请先保存文件。"))
        return
      }
      // FR-7.4 审查修复：裸开异根 md（「仅打开文件」）时 md 不在当前工作区内——
      // 图片会静默写进旧工作区 assets/ 并留下指向旧工作区的相对链接（移动即失效），
      // 必须在落盘前拦下（判定与 ExternalOpenCoordinator.decide 共用，见 isWithinWorkspace 注释）
      guard dir.isWithinWorkspace(root: root) else {
        fail(String(localized: "文件位于当前工作区之外，图片无法保存到工作区 assets。将文件所在文件夹设为工作区（或把文件移入工作区）后再粘贴。"))
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
