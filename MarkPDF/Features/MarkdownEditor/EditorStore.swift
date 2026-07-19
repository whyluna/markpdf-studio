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
  /// 有尚未落盘的改动（工具栏橙点指示；自动保存通常 0.5s 内清除）
  @Published private(set) var hasUnsavedChanges = false
  /// 文档大纲（FR-2.6；内核随内容变更推送）
  @Published var outline: [Heading] = []
  /// 请求内核滚动到指定行（大纲跳转）；由 MarkdownEditorView 消费后清零
  @Published private(set) var pendingScrollLine: Int?

  /// 最近一次与磁盘一致的文本（识别 setContent 回显，避免无意义写盘）
  private var lastPersistedText: String = EditorStore.welcomeDocument
  /// 防抖中的保存任务
  private var pendingSave: DispatchWorkItem?

  /// 自动保存防抖间隔（FR-2.7：停止输入 0.5s 后落盘）
  private static let autosaveDelay: TimeInterval = 0.5

  /// 打开磁盘上的 Markdown 文件（FR-1.1）；切换前先把旧文件的挂起改动写盘
  func loadFile(_ url: URL) {
    guard url != currentFileURL else { return }
    flushPendingSave()
    do {
      let content = try String(contentsOf: url, encoding: .utf8)
      currentFileURL = url
      lastPersistedText = content
      hasUnsavedChanges = false
      text = content
      Logger.editor.info("已打开文件: \(url.lastPathComponent, privacy: .public)")
    } catch {
      Logger.editor.error("读取文件失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }

  /// 大纲跳转请求（FR-2.6）：由 MarkdownEditorView 消费
  func scrollTo(line: Int) {
    pendingScrollLine = line
  }

  /// 内核已消费滚动请求
  func didHandleScroll() {
    pendingScrollLine = nil
  }

  /// 光标行变化回调（FR-1.6 编辑位置记忆；参数为文件 URL 与 1 起行号）
  var onCursorLineChange: ((URL, Int) -> Void)?

  /// 内核光标上报入口（防抖已由内核完成）
  func cursorDidMove(to line: Int) {
    guard let url = currentFileURL else { return }
    onCursorLineChange?(url, line)
  }

  /// 打开的文件被重命名/移动：跟随更新标识（FR-1.2）；
  /// 移动可能触发磁盘链接修正（FR-2.5），磁盘与上次落盘不一致时以磁盘为准重载
  ///（重命名无磁盘变化，不影响未落盘编辑）
  func fileDidMove(from oldURL: URL, to newURL: URL) {
    guard currentFileURL == oldURL else { return }
    currentFileURL = newURL
    if let disk = try? String(contentsOf: newURL, encoding: .utf8), disk != lastPersistedText {
      pendingSave?.cancel()
      pendingSave = nil
      lastPersistedText = disk
      text = disk
      hasUnsavedChanges = false
    }
  }

  /// 打开的文件被移入废纸篓：转为草稿态、停止自动保存（内容保留在编辑器与废纸篓）
  func fileWasTrashed(_ url: URL) {
    guard currentFileURL == url else { return }
    currentFileURL = nil
  }

  /// 内核内容变更入口：更新文本并按需调度自动保存（FR-2.7）
  func contentDidChange(_ newText: String) {
    text = newText
    // setContent 回显（与磁盘一致）不算改动
    guard newText != lastPersistedText else {
      pendingSave?.cancel()
      pendingSave = nil
      hasUnsavedChanges = false
      return
    }
    hasUnsavedChanges = true
    scheduleAutosave()
  }

  /// 立即写入挂起的改动（切换文件 / ⌘S / 应用退出前调用）
  func flushPendingSave() {
    pendingSave?.cancel()
    pendingSave = nil
    saveNowIfNeeded()
  }

  // MARK: - 自动保存（FR-2.7）

  private func scheduleAutosave() {
    pendingSave?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.pendingSave = nil
      self?.saveNowIfNeeded()
    }
    pendingSave = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: item)
  }

  /// 原子写盘：先写临时文件再替换，避免异常中断产生半截文件
  private func saveNowIfNeeded() {
    guard hasUnsavedChanges, let url = currentFileURL else { return }
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      lastPersistedText = text
      hasUnsavedChanges = false
      Logger.editor.debug("自动保存: \(url.lastPathComponent, privacy: .public)")
    } catch {
      Logger.editor.error("自动保存失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }

  deinit {
    pendingSave?.cancel()
  }

  static let welcomeDocument = """
    # 欢迎使用 MarkPDF Studio

    按 **⌘O** 打开一个文件夹作为工作区；在左侧文件树中点击 `.md` 文件即可编辑，PDF 与图片可直接预览。

    编辑会**自动保存**：停止输入 0.5 秒后写回磁盘（原子写入）；文件名旁的橙点表示有未落盘改动。

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
    - [x] 自动保存：停止输入 0.5 秒后落盘（FR-2.7）

    > 明暗主题跟随系统外观自动切换。
    """
}
