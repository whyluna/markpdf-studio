import AppKit
import os
import PDFKit
import SwiftUI

/// 应用根视图：三栏布局（文件树 / 标签内容区 / 上下文面板）+ 底部状态栏。
/// 中间栏为标签组（FR-1.4）：单栏或左右分栏，每组含标签栏与激活标签内容。
struct ContentView: View {
  @EnvironmentObject private var session: WindowSession
  @EnvironmentObject private var workspaceStore: WorkspaceStore
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @EnvironmentObject private var annotationStore: PDFAnnotationStore
  @EnvironmentObject private var searchStore: SearchStore
  @EnvironmentObject private var backlinksStore: BacklinksStore
  @EnvironmentObject private var imageStore: ImagePreviewStore
  @EnvironmentObject private var settingsStore: SettingsStore
  @EnvironmentObject private var aiChatStore: AIChatStore

  var body: some View {
    VStack(spacing: 0) {
      splitView
      StatusBarView()
    }
    // 菜单命令上下文（v1.5 多窗口）：焦点窗口发布，AppCommands 消费；
    // body 随各 store @Published 重算，标志变化即刷新菜单禁用态
    .focusedSceneValue(\.commandContext, commandContext)
    // 退出前兜底落盘（FR-2.7）已挪到 App 级（MarkPDFApp.init 注册 willTerminate）：
    // 挂在视图上时，红钮关窗后再 ⌘Q 无人接收，防抖窗口内的保存/快照会丢
    // 标注写回失败提示（NFR-5；全局唯一挂载点，分栏时不重复呈现）
    .alert(
      "文件操作失败",
      isPresented: Binding(
        get: { annotationStore.lastError != nil },
        set: { if !$0 { annotationStore.lastError = nil } }
      )
    ) {
      Button("好") { annotationStore.lastError = nil }
    } message: {
      Text(annotationStore.lastError ?? "")
    }
    // 快速打开面板（FR-6.1 ⌘P）与全文搜索面板（FR-6.2 ⌘⇧F）与命令面板（FR-6.3 ⌘O）
    .overlay {
      if workspaceStore.isQuickOpenPresented {
        quickOpenOverlay
      } else if workspaceStore.isFullTextSearchPresented {
        fullTextSearchOverlay
      } else if workspaceStore.isCommandPalettePresented {
        commandPaletteOverlay
      }
    }
  }

  /// 菜单命令上下文：状态标志 + 指向本窗口 store 的动作闭包
  private var commandContext: AppCommandContext {
    let kind = tabStore.activeGroup.activeTab?.kind
    var context = AppCommandContext()
    context.zoomable = kind == .pdf || kind == .image
    context.isPDF = kind == .pdf
    context.hasEditor = tabStore.activeEditorStore != nil
    context.canExportAnnotations = annotationStore.currentFileURL != nil
    context.sidecarAvailable = annotationStore.currentFileURL != nil
    context.hasPDFSelection = pdfStore.hasSelection
    context.isFindBarVisible = pdfStore.isFindBarVisible
    context.isSidecarMode = annotationStore.isSidecarMode
    context.isAIVisible = workspaceStore.isAIAssistantPresented
    context.openFolderPanel = { workspaceStore.openFolderPanel() }
    context.showCommandPalette = { workspaceStore.isCommandPalettePresented = true }
    context.showQuickOpen = { workspaceStore.isQuickOpenPresented = true }
    context.showFullTextSearch = { workspaceStore.isFullTextSearchPresented = true }
    context.toggleAIAssistant = { workspaceStore.isAIAssistantPresented.toggle() }
    context.save = { tabStore.activeEditorStore?.flushPendingSave() }
    context.exportPDF = { exportMarkdown(.pdf) }
    context.exportHTML = { exportMarkdown(.html) }
    context.exportAnnotations = { exportAnnotations() }
    context.setSidecarMode = { annotationStore.setSidecarMode($0) }
    context.zoomIn = { zoomAction { $0.zoomIn() } }
    context.zoomOut = { zoomAction { $0.zoomOut() } }
    context.resetZoom = { zoomAction { $0.resetZoom() } }
    context.copyQuote = {
      PDFQuoteExporter.copyAsQuote(
        pdfView: pdfStore.pdfView,
        currentPage: pdfStore.currentPage,
        workspaceRoot: workspaceStore.root?.id
      )
    }
    context.presentFindBar = { pdfStore.presentFindBar() }
    context.findNext = { pdfStore.findNext() }
    context.findPrevious = { pdfStore.findPrevious() }
    return context
  }

  /// 缩放命令路由：PDF → pdfStore，图片 → imageStore
  private func zoomAction(_ action: (ZoomTarget) -> Void) {
    switch tabStore.activeGroup.activeTab?.kind {
    case .pdf: action(pdfStore)
    case .image: action(imageStore)
    default: break
    }
  }

  // MARK: - 三栏布局

  private var splitView: some View {
    // 右侧面板走系统检查器（inspector）：独立于分栏——边栏收放/拖动只影响正文；
    // prominentDetail 样式让正文承担全部宽度分配（边栏展开时右栏不再被压）
    NavigationSplitView {
      // FR-1.1 工作区文件树。列宽上限 360（用户定夺）：SwiftUI 的 max 约束
      // 拖动期间不生效（分隔条可物理拖到 detail 触底，松手后列错位/双侧溢出
      // 且不可恢复）——拖拽条在 AppKit 层给边栏列加 238–360 硬约束，
      // 分隔条拖不出范围，失步无从触发
      FileTreeView()
        .overlay(alignment: .trailing) {
          SidebarDragStrip()
            .frame(width: 6)
            .frame(maxHeight: .infinity)
        }
        .navigationSplitViewColumnWidth(min: 238, ideal: 260, max: 360)
    } detail: {
      tabAreaWithToolbar
        .frame(minWidth: 360)
        .inspector(isPresented: $workspaceStore.isDetailPanelPresented) {
          detailPanel
            .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
        }
    }
  }

  /// 正文栏（标签区 + 窗口工具栏）
  private var tabAreaWithToolbar: some View {
    tabArea
      .toolbar {
        ToolbarItem(placement: .principal) {
          if tabStore.activeGroup.activeTab?.kind == .pdf {
            // PDF 标注工具组（FR-4.4，对齐设计稿 #pdfTools）
            PDFToolsView()
          } else if let store = tabStore.activeEditorStore {
            EditorModePicker(store: store)
          }
        }
        ToolbarItem(placement: .primaryAction) {
          // 导出菜单（设计稿 #btnExport）
          Menu {
            Button("导出为 PDF") {
              exportMarkdown(.pdf)
            }
            .disabled(!canExportMarkdown)
            Button("导出为 HTML") {
              exportMarkdown(.html)
            }
            .disabled(!canExportMarkdown)
            Divider()
            Button("导出全部标注为 Markdown…") {
              exportAnnotations()
            }
            .disabled(!canExportAnnotations)
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          .help("导出")
        }
        ToolbarItem(placement: .primaryAction) {
          // AI 助手（FR-AI.2；⌘⇧A / 命令面板同源开关）
          Button {
            workspaceStore.isAIAssistantPresented.toggle()
          } label: {
            Image(systemName: workspaceStore.isAIAssistantPresented ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
          }
          .help(workspaceStore.isAIAssistantPresented ? "隐藏 AI 助手" : "显示 AI 助手")
        }
        ToolbarItem(placement: .primaryAction) {
          // 分栏切换（FR-1.4；设计稿 #btnSplit）
          Button {
            tabStore.toggleSplit()
          } label: {
            Image(systemName: tabStore.isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
          }
          .help(tabStore.isSplit ? "合并为单栏" : "左右分栏")
        }
        ToolbarItem(placement: .primaryAction) {
          // 右侧面板整栏收起/展开（缩略图/大纲/AI 助手同栏）。
          // 系统检查器开关可能被挤出工具栏——自己的按钮必然可达
          Button {
            withAnimation(.easeInOut(duration: 0.2)) {
              workspaceStore.isDetailPanelPresented.toggle()
            }
          } label: {
            Image(systemName: "sidebar.right")
              .symbolVariant(workspaceStore.isDetailPanelPresented ? .fill : .none)
          }
          .help(workspaceStore.isDetailPanelPresented ? "收起右侧面板" : "展开右侧面板")
        }
      }
  }

  /// 右侧 detail 列宽度约束见 inspectorColumnWidth（280/300/360，系统检查器托管）

  /// 右侧面板：AI 助手可见时整栏替代（FR-AI.2 替代式单栏）；
  /// 否则 pdf 标签 = 缩略图/书签/标注/引用（FR-3.3/5.4），其余 = 大纲（FR-2.6）+ 反向链接（FR-5.4）
  @ViewBuilder
  private var detailPanel: some View {
    if workspaceStore.isAIAssistantPresented {
      AIAssistantPanelView()
    } else if let tab = tabStore.activeGroup.activeTab, tab.kind == .pdf, let url = tab.url {
      PDFSidebarView(url: url)
    } else {
      // 大纲 / 反向链接分界线可拖动（VSplitView）；ideal 高度引导首次分配——反向链接默认占较小空间。
      // 限制：拖动后的比例不持久（macOS 13 SplitView 无比例观测 API，同 FR-1.6 已知偏差）
      VSplitView {
        if let store = tabStore.activeEditorStore {
          OutlinePanelView(store: store) { heading in
            store.scrollTo(line: heading.line)
          }
          .frame(minHeight: 120, idealHeight: 1000, maxHeight: .infinity)
        }
        BacklinksPanelView(target: tabStore.activeGroup.activeTab?.url)
          // 初始限制最大高度：反向链接默认只占底部小块（idealHeight 软引导对 VSplitView 布局无效，改用 maxHeight 硬约束）
          .frame(minHeight: 60, idealHeight: 90, maxHeight: 190)
      }
    }
  }

  // MARK: - 导出（FR-4.8 / FR-2.9）

  /// 当前可导出标注：标注 Store 已关联 PDF 文档（激活标签可以是分栏另一侧的笔记——场景 A）
  private var canExportAnnotations: Bool {
    annotationStore.currentFileURL != nil
  }

  /// 当前可导出 md：激活标签为 md（内核引用不可观测，不做启用条件，避免菜单禁用状态不刷新；
  /// 内核未就绪的极端情况由 MarkdownExportFlow 自行弹提示）
  private var canExportMarkdown: Bool {
    tabStore.activeEditorStore != nil
  }

  /// 导出当前 PDF 的全部标注到目标笔记，并在新标签中打开该笔记
  private func exportAnnotations() {
    guard let url = AnnotationExportFlow.run(store: annotationStore) else { return }
    tabStore.open(url: url)
  }

  /// 导出当前 md 为 PDF / HTML（FR-2.9）
  private func exportMarkdown(_ format: MarkdownExportFlow.Format) {
    guard let store = tabStore.activeEditorStore else { return }
    MarkdownExportFlow.run(format, store: store, workspaceRoot: workspaceStore.root?.id)
  }

  // MARK: - 命令面板（FR-6.3）

  /// 命令面板浮层：顶部居中，点击遮罩关闭
  private var commandPaletteOverlay: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.15)
        .ignoresSafeArea()
        .onTapGesture {
          workspaceStore.isCommandPalettePresented = false
        }
      CommandPaletteView(
        commands: allCommands(),
        onDismiss: {
          workspaceStore.isCommandPalettePresented = false
        }
      )
      .padding(.top, 80)
    }
  }

  /// 全部可执行命令（面板打开时求值 isEnabled）
  private func allCommands() -> [AppCommand] {
    let activeKind = tabStore.activeGroup.activeTab?.kind
    let isPDF = activeKind == .pdf
    let isImage = activeKind == .image
    let hasWorkspace = workspaceStore.root != nil
    var commands: [AppCommand] = []

    // 文件
    commands.append(AppCommand(id: "open-folder", title: String(localized: "打开文件夹…"), section: String(localized: "文件"), shortcut: "⌘⇧O") {
      workspaceStore.openFolderPanel()
    })
    commands.append(AppCommand(id: "new-md", title: String(localized: "新建 Markdown 文件"), section: String(localized: "文件"), isEnabled: { hasWorkspace }) {
      _ = workspaceStore.createMarkdown(in: workspaceStore.root!.id, undo: nil)  // root 已由 isEnabled 保证
    })
    commands.append(AppCommand(id: "new-folder", title: String(localized: "新建文件夹"), section: String(localized: "文件"), isEnabled: { hasWorkspace }) {
      _ = workspaceStore.createFolder(in: workspaceStore.root!.id, undo: nil)
    })
    commands.append(AppCommand(id: "save", title: String(localized: "保存"), section: String(localized: "文件"), shortcut: "⌘S", isEnabled: { tabStore.activeEditorStore != nil }) {
      tabStore.activeEditorStore?.flushPendingSave()
    })
    commands.append(AppCommand(id: "quick-open", title: String(localized: "快速打开…"), section: String(localized: "文件"), shortcut: "⌘P", isEnabled: { hasWorkspace }) {
      workspaceStore.isQuickOpenPresented = true
    })
    commands.append(AppCommand(id: "full-search", title: String(localized: "全文搜索…"), section: String(localized: "文件"), shortcut: "⌘⇧F", isEnabled: { hasWorkspace }) {
      workspaceStore.isFullTextSearchPresented = true
    })

    // 导出
    commands.append(AppCommand(id: "export-pdf", title: String(localized: "导出为 PDF"), section: String(localized: "导出"), isEnabled: { canExportMarkdown }) {
      exportMarkdown(.pdf)
    })
    commands.append(AppCommand(id: "export-html", title: String(localized: "导出为 HTML"), section: String(localized: "导出"), isEnabled: { canExportMarkdown }) {
      exportMarkdown(.html)
    })
    commands.append(AppCommand(id: "export-annotations", title: String(localized: "导出全部标注为 Markdown…"), section: String(localized: "导出"), isEnabled: { canExportAnnotations }) {
      exportAnnotations()
    })

    // 视图
    commands.append(AppCommand(id: "split", title: tabStore.isSplit ? String(localized: "合并为单栏") : String(localized: "左右分栏"), section: String(localized: "视图")) {
      tabStore.toggleSplit()
    })
    commands.append(AppCommand(id: "zoom-in", title: String(localized: "放大"), section: String(localized: "视图"), shortcut: "⌘=", isEnabled: { isPDF || isImage }) {
      if isPDF { pdfStore.zoomIn() } else { imageStore.zoomIn() }
    })
    commands.append(AppCommand(id: "zoom-out", title: String(localized: "缩小"), section: String(localized: "视图"), shortcut: "⌘-", isEnabled: { isPDF || isImage }) {
      if isPDF { pdfStore.zoomOut() } else { imageStore.zoomOut() }
    })
    commands.append(AppCommand(id: "zoom-reset", title: String(localized: "实际大小"), section: String(localized: "视图"), shortcut: "⌘0", isEnabled: { isPDF || isImage }) {
      if isPDF { pdfStore.resetZoom() } else { imageStore.resetZoom() }
    })
    for mode in MarkdownEditorView.EditorMode.allCases {
      commands.append(AppCommand(
        id: "mode-\(mode.rawValue)", title: String(localized: "编辑模式：\(mode.title)"), section: String(localized: "视图"),
        isEnabled: { tabStore.activeEditorStore != nil }
      ) {
        tabStore.activeEditorStore?.mode = mode
      })
    }

    // PDF
    commands.append(AppCommand(id: "find", title: String(localized: "在文档中查找…"), section: String(localized: "PDF"), shortcut: "⌘F", isEnabled: { isPDF }) {
      pdfStore.presentFindBar()
    })
    commands.append(AppCommand(id: "find-next", title: String(localized: "查找下一个"), section: String(localized: "PDF"), shortcut: "⌘G", isEnabled: { pdfStore.isFindBarVisible }) {
      pdfStore.findNext()
    })
    commands.append(AppCommand(id: "find-prev", title: String(localized: "查找上一个"), section: String(localized: "PDF"), shortcut: "⇧⌘G", isEnabled: { pdfStore.isFindBarVisible }) {
      pdfStore.findPrevious()
    })
    commands.append(AppCommand(id: "copy-quote", title: String(localized: "复制为带回链的引用"), section: String(localized: "PDF"), shortcut: "⇧⌘C", isEnabled: { isPDF && pdfStore.hasSelection }) {
      PDFQuoteExporter.copyAsQuote(
        pdfView: pdfStore.pdfView,
        currentPage: pdfStore.currentPage,
        workspaceRoot: workspaceStore.root?.id
      )
    })
    commands.append(AppCommand(
      id: "sidecar",
      title: annotationStore.isSidecarMode ? String(localized: "关闭只读标注模式") : String(localized: "开启只读标注模式"),
      section: String(localized: "PDF"),
      isEnabled: { annotationStore.currentFileURL != nil }
    ) {
      annotationStore.setSidecarMode(!annotationStore.isSidecarMode)
    })
    for kind in AnnotationKind.allCases {
      commands.append(AppCommand(
        id: "tool-\(kind.rawValue)", title: String(localized: "标注工具：\(kind.title)"), section: String(localized: "PDF"),
        isEnabled: { isPDF }
      ) {
        annotationStore.activeTool = kind
      })
    }

    // 其他
    // 全局外观（明暗）：替代原「PDF 阅读主题」——统一控制侧边栏/MD/PDF 反色
    for appearance in SettingsStore.AppAppearance.allCases {
      commands.append(AppCommand(
        id: "appearance-\(appearance.rawValue)",
        title: String(localized: "外观：\(appearance.title)"),
        section: String(localized: "视图")
      ) {
        settingsStore.appAppearance = appearance
      })
    }
    commands.append(AppCommand(id: "typewriter", title: String(localized: "切换打字机模式"), section: String(localized: "视图"), isEnabled: { tabStore.activeEditorStore != nil }) {
      settingsStore.typewriterMode.toggle()
    })
    commands.append(AppCommand(id: "focus-mode", title: String(localized: "切换专注模式"), section: String(localized: "视图"), isEnabled: { tabStore.activeEditorStore != nil }) {
      settingsStore.focusMode.toggle()
    })
    commands.append(AppCommand(
      id: "ai-assistant",
      title: workspaceStore.isAIAssistantPresented ? String(localized: "隐藏 AI 助手") : String(localized: "显示 AI 助手"),
      section: String(localized: "视图"),
      shortcut: "⌘⇧A"
    ) {
      workspaceStore.isAIAssistantPresented.toggle()
    })
    commands.append(AppCommand(id: "settings", title: String(localized: "设置…"), section: String(localized: "其他"), shortcut: "⌘,") {
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    })
    return commands
  }

  // MARK: - 标签内容区

  private var tabArea: some View {
    HStack(spacing: 0) {
      if tabStore.isSplit {
        HSplitView {
          TabGroupPane(group: tabStore.groups[0])
          TabGroupPane(group: tabStore.groups[1])
        }
      } else {
        TabGroupPane(group: tabStore.groups[0])
      }
      // 右边缘落点：拖标签到窗口右缘创建/移入右组（FR-1.4 拖拽至边缘分栏）
      EdgeTabDropZone()
    }
  }

  /// 全文搜索浮层：顶部居中，点击遮罩关闭；命中跳转（md 跳行 / pdf 跳页）
  private var fullTextSearchOverlay: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.15)
        .ignoresSafeArea()
        .onTapGesture {
          workspaceStore.isFullTextSearchPresented = false
        }
      FullTextSearchView(
        store: searchStore,
        rootPath: workspaceStore.root?.id.path ?? "",
        onSelect: { result in
          workspaceStore.isFullTextSearchPresented = false
          tabStore.open(url: result.url)
          switch result.kind {
          case .markdown:
            // 内核未就绪时滚动请求排队，就绪后补发（不丢）
            tabStore.activeEditorStore?.scrollTo(line: result.location)
          case .pdf:
            // 跳转携带目标文件 URL：分栏双 PDF 时仅目标文档所在视图可消费
            pdfStore.pendingJump = (url: result.url, page: result.location)
          default:
            break
          }
        },
        onDismiss: {
          workspaceStore.isFullTextSearchPresented = false
        }
      )
      .padding(.top, 80)
    }
  }

  /// 快速打开浮层：顶部居中，点击遮罩关闭
  private var quickOpenOverlay: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.15)
        .ignoresSafeArea()
        .onTapGesture {
          workspaceStore.isQuickOpenPresented = false
        }
      QuickOpenView(
        files: workspaceStore.allFiles,
        rootPath: workspaceStore.root?.id.path ?? "",
        onSelect: { node in
          workspaceStore.selection = node
          tabStore.open(node)
          workspaceStore.isQuickOpenPresented = false
        },
        onDismiss: {
          workspaceStore.isQuickOpenPresented = false
        }
      )
      .padding(.top, 80)
    }
  }
}

/// 编辑模式选择器（工具栏）：显式 @ObservedObject 注入 EditorStore——
/// 嵌套 ObservableObject 的变化不向上冒泡，命令面板等外部入口切模式后选择器即时跟随
private struct EditorModePicker: View {
  @ObservedObject var store: EditorStore

  var body: some View {
    Picker("编辑模式", selection: Binding(
      get: { store.mode },
      set: { store.mode = $0 }
    )) {
      ForEach(MarkdownEditorView.EditorMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 260)
  }
}

/// 窗口右缘的标签落点：拖标签到此处创建/移入最右侧组
private struct EdgeTabDropZone: View {
  @EnvironmentObject private var tabStore: TabStore
  @State private var isTargeted = false

  var body: some View {
    Color.clear
      .frame(width: 10)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
          .padding(4)
      )
      .onDrop(of: [.text], isTargeted: $isTargeted) { _ in
        guard let dragging = tabStore.draggingTab,
          let source = tabStore.groups.first(where: { $0.id == dragging.from })
        else { return false }
        let target = tabStore.isSplit ? tabStore.groups.last : nil
        tabStore.moveTab(dragging.tab, from: source, to: target)
        tabStore.draggingTab = nil
        return true
      }
  }
}

#Preview {
  ContentView()
    .environmentObject(WindowSession(
      snapshotStore: WorkspaceSnapshotStore(),
      aiSettings: AISettingsStore(),
      aiKeys: AIKeyStore(),
      aiSessions: AISessionRepository()
    ))
    .environmentObject(WorkspaceStore())
    .environmentObject(TabStore())
    .environmentObject(PDFReaderStore())
    .environmentObject(PDFBookmarksStore())
    .environmentObject(WorkspaceStateStore())
}


/// 左侧边栏分隔条加宽拖拽条（系统分隔线命中区太窄的根治）：
/// 叠在边栏列右缘 6pt，命中即左右箭头；拖动循环直接拨 NSSplitView 分隔条
///（不走 SwiftUI 逐帧更新，手感与右栏检查器完全一致）
private struct SidebarDragStrip: NSViewRepresentable {
  func makeNSView(context: Context) -> SidebarDragStripNSView {
    SidebarDragStripNSView()
  }

  func updateNSView(_ nsView: SidebarDragStripNSView, context: Context) {}
}

final class SidebarDragStripNSView: NSView {
  /// 已加宽度硬约束的分隔视图（SwiftUI 重建分隔视图后需重装，按窗口存活判断）
  private var constrainedSplit: NSSplitView?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    installWidthConstraints()
  }

  /// 边栏列宽硬约束（238–360，priority 999）：SwiftUI 的 min/max 约束
  /// 拖动期间不生效——分隔条可物理拖到 detail 触底（约 888pt），松手后
  /// SwiftUI 记账与显示失步（列错位/双侧溢出，且失步后不可恢复）。
  /// AppKit 层把分隔条的物理行程限死在合法区间，SwiftUI 永远见不到
  /// 越界值，失步无从触发；优先级 999 不与 SwiftUI 必需约束打架
  private func installWidthConstraints() {
    if let split = constrainedSplit, split.window != nil { return }
    constrainedSplit = nil
    guard let split = Self.findSplitView(in: window?.contentView),
      split.arrangedSubviews.count >= 2
    else { return }
    let sidebar = split.arrangedSubviews[0]
    let lower = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 238)
    let upper = sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
    for constraint in [lower, upper] {
      constraint.priority = .init(999)
      constraint.isActive = true
    }
    constrainedSplit = split
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  /// 事件重定向：把落在加宽带上的按下转交给分隔条中心的系统拖动跟踪——
  /// 自己拨条会与 NavigationSplitView 的宽度同步回环打架（从左侧接近必抖的根因），
  /// 系统接管后手感与右栏检查器完全一致
  override func mouseDown(with event: NSEvent) {
    installWidthConstraints()
    guard let window, let split = Self.findSplitView(in: window.contentView),
      split.arrangedSubviews.count >= 2
    else { return }
    let dividerCenterInSplit = NSPoint(
      x: split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2,
      y: split.bounds.midY
    )
    let inWindow = split.convert(dividerCenterInSplit, to: nil)
    guard let redirected = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: inWindow,
      modifierFlags: event.modifierFlags,
      timestamp: event.timestamp,
      windowNumber: event.windowNumber,
      context: nil,
      eventNumber: event.eventNumber,
      clickCount: 1,
      pressure: 1
    ) else { return }
    split.mouseDown(with: redirected)
  }

  private static func findSplitView(in view: NSView?) -> NSSplitView? {
    guard let view else { return nil }
    if let split = view as? NSSplitView { return split }
    for subview in view.subviews {
      if let found = findSplitView(in: subview) { return found }
    }
    return nil
  }
}
