import Foundation
import os

/// 编辑器状态对象（开发规范 §3.2：macOS 13 兼容，采用 ObservableObject）。
/// 当前为单文档占位实现；标签页/多文档接入后按文档拆分。
final class EditorStore: ObservableObject {
  /// 当前文档文本（内核变更实时同步到这里）
  @Published var text: String = EditorStore.welcomeDocument
  /// 编辑模式
  @Published var mode: MarkdownEditorView.EditorMode = .wysiwyg

  /// 内核内容变更入口：后续在此接入防抖落盘（FR-2.7）
  func contentDidChange(_ newText: String) {
    text = newText
    // TODO(FR-2.7): 防抖 500ms 原子写盘
  }

  static let welcomeDocument = """
    # 欢迎使用 MarkPDF Studio

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
    - [ ] 文件树打开真实文档（FR-1.1）

    > 明暗主题跟随系统外观自动切换。
    """
}
