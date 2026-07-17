import Foundation
import os

/// 编辑器状态对象（开发规范 §3.2：macOS 13 兼容，采用 ObservableObject）。
/// 当前为单文档实现；标签页/多文档接入后按文档拆分。
final class EditorStore: ObservableObject {
  /// 当前文档文本（内核变更实时同步到这里）
  @Published var text: String = EditorStore.welcomeDocument
  /// 编辑模式
  @Published var mode: MarkdownEditorView.EditorMode = .wysiwyg
  /// 当前打开的磁盘文件（nil = 欢迎页草稿）
  @Published private(set) var currentFileURL: URL?

  /// 打开磁盘上的 Markdown 文件（FR-1.1）
  func loadFile(_ url: URL) {
    guard url != currentFileURL else { return }
    do {
      let content = try String(contentsOf: url, encoding: .utf8)
      currentFileURL = url
      text = content
      Logger.editor.info("已打开文件: \(url.lastPathComponent, privacy: .public)")
    } catch {
      Logger.editor.error("读取文件失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }

  /// 内核内容变更入口：自动保存（FR-2.7）随下一提交接入
  func contentDidChange(_ newText: String) {
    text = newText
  }

  static let welcomeDocument = """
    # 欢迎使用 MarkPDF Studio

    按 **⌘O** 打开一个文件夹作为工作区；在左侧文件树中点击 `.md` 文件即可编辑，PDF 与图片可直接预览。

    这是运行在 **WKWebView** 里的 CodeMirror 6 内核。光标进入某一行，它会显示源码；移开即渲染。

    - 支持 **加粗**、*斜体*、~~删除线~~、`行内代码`
    - 支持 [链接](https://github.com/whyluna/markpdf-studio)、引用、任务列表
    - 右上角可切换 所见即所得 / 源码 / 阅读 三种模式

    ```swift
    // 代码块语法高亮
    let bridge = WebBridge()
    bridge.notify("editor.setContent", payload: ["text": text])
    ```

    - [x] 内核嵌入 App
    - [x] 文件树打开真实文档（FR-1.1）
    - [ ] 自动保存（FR-2.7）

    > 明暗主题跟随系统外观自动切换。
    """
}
