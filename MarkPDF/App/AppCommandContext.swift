import SwiftUI

/// 菜单命令的窗口上下文（v1.5 多窗口）：激活窗口经 `.focusedSceneValue` 发布，
/// AppCommands 经 `@FocusedValue` 消费——命令作用于焦点窗口而非 App 级单例。
/// Equatable 只比状态标志（闭包不参与），标志变化即触发菜单禁用态刷新
struct AppCommandContext: Equatable {
  // MARK: - 状态标志（Equatable 依据）

  var zoomable = false
  var isPDF = false
  var hasEditor = false
  var canExportAnnotations = false
  var hasPDFSelection = false
  var isFindBarVisible = false
  var isSidecarMode = false
  var sidecarAvailable = false
  var isAIVisible = false

  // MARK: - 动作（指向焦点窗口的闭包，不参与比较）

  var openFolderPanel: () -> Void = {}
  var showCommandPalette: () -> Void = {}
  var showQuickOpen: () -> Void = {}
  var showFullTextSearch: () -> Void = {}
  var toggleAIAssistant: () -> Void = {}
  var save: () -> Void = {}
  var exportPDF: () -> Void = {}
  var exportHTML: () -> Void = {}
  var exportAnnotations: () -> Void = {}
  var setSidecarMode: (Bool) -> Void = { _ in }
  var zoomIn: () -> Void = {}
  var zoomOut: () -> Void = {}
  var resetZoom: () -> Void = {}
  var copyQuote: () -> Void = {}
  var presentFindBar: () -> Void = {}
  var findNext: () -> Void = {}
  var findPrevious: () -> Void = {}

  static func == (lhs: AppCommandContext, rhs: AppCommandContext) -> Bool {
    lhs.zoomable == rhs.zoomable
      && lhs.isPDF == rhs.isPDF
      && lhs.hasEditor == rhs.hasEditor
      && lhs.canExportAnnotations == rhs.canExportAnnotations
      && lhs.hasPDFSelection == rhs.hasPDFSelection
      && lhs.isFindBarVisible == rhs.isFindBarVisible
      && lhs.isSidecarMode == rhs.isSidecarMode
      && lhs.sidecarAvailable == rhs.sidecarAvailable
      && lhs.isAIVisible == rhs.isAIVisible
  }
}

struct AppCommandContextKey: FocusedValueKey {
  typealias Value = AppCommandContext
}

extension FocusedValues {
  var commandContext: AppCommandContext? {
    get { self[AppCommandContextKey.self] }
    set { self[AppCommandContextKey.self] = newValue }
  }
}

/// 主菜单命令（从 MarkPDFApp.commands 迁出）：全部经 FocusedValue 路由到焦点窗口；
/// 无焦点窗口（如仅设置窗）时禁用
struct AppCommands: Commands {
  @FocusedValue(\.commandContext) private var context

  var body: some Commands {
    CommandGroup(after: .newItem) {
      // 命令面板（FR-6.3 ⌘O）；「打开文件夹」让位改 ⌘⇧O
      Button("命令面板…") {
        context?.showCommandPalette()
      }
      .keyboardShortcut("o")
      .disabled(context == nil)
      Button("打开文件夹…") {
        context?.openFolderPanel()
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
      .disabled(context == nil)
      Button("快速打开…") {
        context?.showQuickOpen()
      }
      .keyboardShortcut("p")
      .disabled(context == nil)
      // 全文搜索（FR-6.2 ⌘⇧F）
      Button("全文搜索…") {
        context?.showFullTextSearch()
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .disabled(context == nil)
      // AI 助手（FR-AI.2 ⌘⇧A：替代式单栏切换）
      Button(context?.isAIVisible == true ? "隐藏 AI 助手" : "显示 AI 助手") {
        context?.toggleAIAssistant()
      }
      .keyboardShortcut("a", modifiers: [.command, .shift])
      .disabled(context == nil)
      Divider()
      // 导出当前 md（FR-2.9）/ 导出全部标注（FR-4.8，导出后打开目标笔记）
      Button("导出为 PDF") {
        context?.exportPDF()
      }
      .disabled(context?.hasEditor != true)
      Button("导出为 HTML") {
        context?.exportHTML()
      }
      .disabled(context?.hasEditor != true)
      Button("导出全部标注为 Markdown…") {
        context?.exportAnnotations()
      }
      .disabled(context?.canExportAnnotations != true)
      Divider()
      // 只读标注模式（FR-4.7）：逐文件切换，标注存同名 sidecar JSON
      Toggle(
        "只读标注模式",
        isOn: Binding(
          get: { context?.isSidecarMode ?? false },
          set: { context?.setSidecarMode($0) }
        )
      )
      .disabled(context?.sidecarAvailable != true)
    }
    CommandGroup(replacing: .saveItem) {
      Button("保存") {
        context?.save()
      }
      .keyboardShortcut("s")
      .disabled(context?.hasEditor != true)
    }
    // 缩放快捷键（FR-3.2）：⌘= 放大、⌘- 缩小、⌘0 实际大小（PDF / 图片均可）
    CommandGroup(after: .toolbar) {
      Button("放大") {
        context?.zoomIn()
      }
      .keyboardShortcut("=", modifiers: .command)
      .disabled(context?.zoomable != true)
      Button("缩小") {
        context?.zoomOut()
      }
      .keyboardShortcut("-", modifiers: .command)
      .disabled(context?.zoomable != true)
      Button("实际大小") {
        context?.resetZoom()
      }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(context?.zoomable != true)
    }
    // PDF 页内搜索（FR-3.4）：⌘F 查找栏、⌘G 下一个、⇧⌘G 上一个
    CommandGroup(after: .textEditing) {
      // 复制为带回链的引用块（FR-5.2）：引用块 + 页码回链，粘贴进 md 可跳转
      Button("复制为带回链的引用") {
        context?.copyQuote()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(context?.isPDF != true || context?.hasPDFSelection != true)
      Button("在文档中查找…") {
        context?.presentFindBar()
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(context?.isPDF != true)
      Button("查找下一个") {
        context?.findNext()
      }
      .keyboardShortcut("g", modifiers: .command)
      .disabled(context?.isFindBarVisible != true)
      Button("查找上一个") {
        context?.findPrevious()
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])
      .disabled(context?.isFindBarVisible != true)
    }
  }
}
