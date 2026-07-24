import Foundation
import os

/// 编辑器状态对象（开发规范 §3.2：macOS 13 兼容，采用 ObservableObject）。
/// 当前为单文档实现；标签页/多文档接入后按文档拆分。
final class EditorStore: ObservableObject {
  /// 当前文档文本（内核变更实时同步到这里）
  @Published var text: String = EditorStore.welcomeDocument {
    didSet { scheduleStatsRefresh() }
  }
  /// 文本统计（FR-2.8：字数/字符/阅读时长，随内容更新；防抖 0.5s，见 scheduleStatsRefresh）
  @Published private(set) var stats: EditorStats = TextStatistics.of(EditorStore.welcomeDocument)
  /// 编辑模式
  @Published var mode: MarkdownEditorView.EditorMode = .wysiwyg
  /// 当前打开的磁盘文件（nil = 欢迎页草稿）
  @Published private(set) var currentFileURL: URL?
  /// 被移入废纸篓前的文件 URL（转草稿后据此识别「从废纸篓恢复」场景；成功载入后清空）
  private(set) var trashedFileURL: URL?
  /// 有尚未落盘的改动（工具栏橙点指示；自动保存通常 0.5s 内清除）
  @Published private(set) var hasUnsavedChanges = false
  /// 最近一次文件读写错误（视图据此弹 alert 后置回 nil；NFR-5：文件操作异常须用户可感知）
  @Published var lastError: String?
  /// 文档大纲（FR-2.6；内核随内容变更推送）
  @Published var outline: [Heading] = []
  /// 请求内核滚动到指定行（大纲跳转）；由 MarkdownEditorView 消费后清零
  @Published private(set) var pendingScrollLine: Int?

  /// 最近一次与磁盘一致的文本（识别 setContent 回显，避免无意义写盘）
  private var lastPersistedText: String = EditorStore.welcomeDocument
  /// 防抖中的保存任务
  private var pendingSave: DispatchWorkItem?
  /// 自动保存持续失败只提示一次（内容每变一次都会重试失败），写盘恢复后复位
  private var hasReportedSaveFailure = false
  /// 统计防抖器（计算在后台串行队列执行，见 scheduleStatsRefresh）
  private let statsDebouncer = Debouncer(interval: 0.5, queue: EditorStore.statsQueue)
  /// 文件加载代际号：加载完成前用户切走/再次 loadFile 时丢弃过期结果（PDFReaderView loadToken 同款先例）
  private var loadToken = 0
  /// 在途加载的目标（加载完成前 fileWasTrashed / fileDidMove 等场景据此识别并干预）
  private var inflightLoadURL: URL?

  /// 自动保存防抖间隔（FR-2.7：停止输入 0.5s 后落盘）
  private static let autosaveDelay: TimeInterval = 0.5
  /// 文本统计后台串行队列（计算结果按调度顺序回主线程落地，保证收敛到最新文本）
  private static let statsQueue = DispatchQueue(label: "markpdf.editor.stats")
  /// 写盘后台串行队列（全局共享：写按发出顺序执行，同一文件后写覆盖先写）
  private static let writeQueue = DispatchQueue(label: "markpdf.editor.save")

  /// 打开磁盘上的 Markdown 文件（FR-1.1）；切换前先把旧文件的挂起改动写盘。
  /// 后台读盘 + 主线程应用（主线程不做同步 IO）；代际号防止过期结果覆盖新状态。
  func loadFile(_ url: URL) {
    guard url != currentFileURL, url != inflightLoadURL else { return }
    flushPendingSave()
    loadToken += 1
    let token = loadToken
    inflightLoadURL = url
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try String(contentsOf: url, encoding: .utf8) }
      DispatchQueue.main.async { [weak self] in
        guard let self, token == self.loadToken else { return }
        self.inflightLoadURL = nil
        switch result {
        case .success(let content):
          self.currentFileURL = url
          self.trashedFileURL = nil
          self.lastPersistedText = content
          self.hasUnsavedChanges = false
          self.text = content
          Logger.editor.info("已打开文件: \(url.lastPathComponent, privacy: .public)")
        case .failure(let error):
          Logger.editor.error("读取文件失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
          self.lastError = String(localized: "无法打开「\(url.lastPathComponent)」：\(error.localizedDescription)")
        }
      }
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
  ///（重命名无磁盘变化，不影响未落盘编辑）。重读走后台，主线程只做状态收口。
  func fileDidMove(from oldURL: URL, to newURL: URL) {
    // 在途加载的目标是旧路径：结果已过期，作废并改从新路径重新加载
    //（加载未落地，本文件尚无未保存编辑可丢；旧文件的挂起改动由 loadFile 内 flush 保住）
    if inflightLoadURL == oldURL {
      inflightLoadURL = nil
      loadFile(newURL)
      return
    }
    guard currentFileURL == oldURL else { return }
    currentFileURL = newURL
    loadToken += 1
    let token = loadToken
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let disk = try? String(contentsOf: newURL, encoding: .utf8) else { return }
      DispatchQueue.main.async { [weak self] in
        // 重读落地前状态可能已被后续操作（再次移动/切换文件/新改动落盘）改写，逐项校验
        guard let self, token == self.loadToken, self.currentFileURL == newURL,
          disk != self.lastPersistedText
        else { return }
        self.pendingSave?.cancel()
        self.pendingSave = nil
        self.lastPersistedText = disk
        self.text = disk
        self.hasUnsavedChanges = false
      }
    }
  }

  /// 打开的文件被移入废纸篓：转为草稿态、停止自动保存（内容保留在编辑器与废纸篓）。
  /// 草稿无落盘目标：取消挂起的自动保存并清掉未保存标记（否则橙点常亮不灭）；
  /// 记下原路径，文件从废纸篓放回原位后重新点击时由 TabGroup 触发重载
  func fileWasTrashed(_ url: URL) {
    guard currentFileURL == url || inflightLoadURL == url else { return }
    // 作废在途加载（若有），避免加载完成后把已入废纸篓的文件重新认作当前文件
    loadToken += 1
    inflightLoadURL = nil
    currentFileURL = nil
    trashedFileURL = url
    pendingSave?.cancel()
    pendingSave = nil
    hasUnsavedChanges = false
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

  /// 立即写入挂起的改动（切换文件 / ⌘S / 应用退出前调用）。
  /// 屏障等待写盘队列排空：返回时改动确已落盘（退出/关标签兜底语义与同步写盘一致）
  func flushPendingSave() {
    pendingSave?.cancel()
    pendingSave = nil
    saveNowIfNeeded()
    EditorStore.writeQueue.sync {}
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

  /// 原子写盘（String.write atomically：先写临时文件再替换，避免异常中断产生半截文件）。
  /// 取 text 快照后在后台串行队列写盘（主线程不做同步 IO）；
  /// hasUnsavedChanges / lastPersistedText 统一在主线程写盘完成回调里收口，保持既有语义：
  /// 写盘成功才推进 lastPersistedText；写盘期间的新改动保持未保存标记，由下一次调度再写；
  /// 写失败仍走 lastError 提示路径（持续失败只提示一次）。
  private func saveNowIfNeeded() {
    guard hasUnsavedChanges, let url = currentFileURL else { return }
    let snapshot = text
    EditorStore.writeQueue.async { [weak self] in
      do {
        try snapshot.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, self.currentFileURL == url else { return }
          Logger.editor.error("自动保存失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
          // 持续失败只提示一次（内容每变一次就重试一次），避免击键级弹窗轰炸
          if !self.hasReportedSaveFailure {
            self.hasReportedSaveFailure = true
            self.lastError = String(localized: "自动保存失败「\(url.lastPathComponent)」：\(error.localizedDescription)")
          }
        }
        return
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.currentFileURL == url else { return }
        self.lastPersistedText = snapshot
        // 写盘期间又有新改动：保持未保存标记，等待下一次调度
        self.hasUnsavedChanges = self.text != snapshot
        self.hasReportedSaveFailure = false
        Logger.editor.debug("自动保存: \(url.lastPathComponent, privacy: .public)")
      }
    }
  }

  // MARK: - 文本统计（FR-2.8）

  /// 统计防抖：击键路径不再逐键 O(n) 全量扫描；停止输入 0.5s 后在后台串行队列计算、
  /// 回主线程应用。串行队列保证结果按调度顺序落地——连续变更时只有最后一次变更的
  /// 快照会算到底（先前挂起项被防抖取消；已在算的过期结果随后也会被最新结果覆盖），
  /// 最终值必收敛到最新文本（防抖只影响刷新时机，不影响统计口径）。
  private func scheduleStatsRefresh() {
    let snapshot = text
    statsDebouncer.schedule { [weak self] in
      let result = TextStatistics.of(snapshot)
      DispatchQueue.main.async { [weak self] in
        self?.stats = result
      }
    }
  }

  deinit {
    pendingSave?.cancel()
    statsDebouncer.cancel()
  }

  /// 欢迎文档（按界面语言选择；大段内容不进 catalog，双语两份字面量）。
  /// 语言重启后生效，启动时读一次持久化键即可（与 SettingsStore.effectiveWebLocale 同口径）
  static var welcomeDocument: String {
    SettingsStore.launchWebLocale == "zh" ? welcomeDocumentZH : welcomeDocumentEN
  }

  static let welcomeDocumentZH = """
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
    bridge.notify(.setContent, payload: ["text": text])
    ```

    - [x] 内核嵌入 App
    - [x] 文件树打开真实文档（FR-1.1）
    - [x] 自动保存：停止输入 0.5 秒后落盘（FR-2.7）

    > 明暗主题跟随系统外观自动切换。
    """

  static let welcomeDocumentEN = """
    # Welcome to MarkPDF Studio

    Press **⌘O** to open a folder as your workspace. Click a `.md` file in the file tree to edit it; PDFs and images open as previews.

    Edits are **auto-saved**: written to disk 0.5s after you stop typing (atomic writes). An orange dot next to the file name means unsaved changes.

    This is a CodeMirror 6 engine running inside **WKWebView**. Move the cursor into a line to see its source; move away and it renders.

    - Supports **bold**, *italic*, ~~strikethrough~~, `inline code`
    - Supports [links](https://github.com/whyluna/markpdf-studio), quotes, and task lists
    - Switch between WYSIWYG / Source / Reading modes in the top-right corner

    ```swift
    // Syntax-highlighted code block
    let bridge = WebBridge()
    bridge.notify(.setContent, payload: ["text": text])
    ```

    - [x] Engine embedded in the app
    - [x] File tree opens real documents (FR-1.1)
    - [x] Auto-save: flushed 0.5s after typing stops (FR-2.7)

    > Light/dark theme follows the system appearance.
    """
}
