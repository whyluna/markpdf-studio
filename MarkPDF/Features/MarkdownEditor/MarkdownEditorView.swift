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
  /// 内核内容变更回调（自动保存挂钩，FR-2.7）
  var onContentChanged: ((String) -> Void)?

  init(
    text: Binding<String>,
    documentID: URL? = nil,
    mode: EditorMode = .wysiwyg,
    theme: EditorTheme = .light,
    onContentChanged: ((String) -> Void)? = nil
  ) {
    _text = text
    self.documentID = documentID
    self.mode = mode
    self.theme = theme
    self.onContentChanged = onContentChanged
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    // 背景交给内核 CSS（明暗主题），避免白闪
    webView.setValue(false, forKey: "drawsBackground")

    let bridge = context.coordinator.bridge
    bridge.attach(to: webView)
    bridge.on("editor.ready") { [weak coordinator = context.coordinator] _, _ in
      // 桥接回调是非隔离闭包：跳到 MainActor 再触达 Coordinator（@MainActor）
      Task { @MainActor in
        coordinator?.kernelDidReady()
      }
    }
    bridge.on("editor.contentChanged") { [weak self] payload, _ in
      guard let text = payload["text"] as? String else { return }
      Task { @MainActor in
        self?.onContentChanged?(text)
      }
    }

    guard let pageURL = Bundle.main.url(forResource: "index", withExtension: "html") else {
      Logger.editor.fault("缺少内核页面 index.html（先执行 npm run build，并确认 Web/dist 已加入 target）")
      return webView
    }
    webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
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
  }
}

// MARK: - Coordinator

extension MarkdownEditorView {
  @MainActor
  final class Coordinator {
    var parent: MarkdownEditorView
    let bridge = WebBridge()

    private var isReady = false
    private var lastPushedMode: EditorMode?
    private var lastPushedTheme: EditorTheme?
    /// 已载入内核的外部文档标识（去重，避免每次宿主刷新都重置内容）
    var lastDocumentID: URL?

    init(_ parent: MarkdownEditorView) {
      self.parent = parent
    }

    /// 内核加载完成：注入初始内容与当前模式/主题
    func kernelDidReady() {
      isReady = true
      bridge.notify("editor.setContent", payload: ["text": parent.text])
      lastDocumentID = parent.documentID
      lastPushedMode = nil
      lastPushedTheme = nil
      pushModeAndThemeIfNeeded()
    }

    /// 将宿主的模式/主题同步给内核（去重，避免无效 JS 调用）
    func pushModeAndThemeIfNeeded() {
      guard isReady else { return }
      if lastPushedMode != parent.mode {
        bridge.notify("editor.setMode", payload: ["mode": parent.mode.rawValue])
        lastPushedMode = parent.mode
      }
      if lastPushedTheme != parent.theme {
        bridge.notify("editor.setTheme", payload: ["theme": parent.theme.rawValue])
        lastPushedTheme = parent.theme
      }
    }

    /// 外部载入新文档（打开文件时使用）；整体替换内容，不打断内核撤销栈之外的编辑
    func loadDocument(_ text: String) {
      guard isReady else { return }
      bridge.notify("editor.setContent", payload: ["text": text])
    }

    /// 从内核取回最新文本（保存快捷键等场景）
    func fetchContent(completion: @escaping (String) -> Void) {
      bridge.request("editor.getContent") { result in
        if case .success(let payload) = result, let text = payload["text"] as? String {
          completion(text)
        }
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
