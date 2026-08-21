import AppKit
import os
import PDFKit
import QuartzCore
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
    // 窗口工具栏挂最外层：挂在正文 HStack 内会随右栏拖拽/收放一起被挤动
    .toolbar { toolbarContent }
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
    // 拖拽幽灵标签（VSCode 式）：被拖标签以浮起卡片跟随指针
    .overlay {
      TabDragGhostOverlay()
    }
  }

  /// 拖拽幽灵浮层（VSCode 式）：被拖标签跟随指针的浮起卡片。
  /// 自观测拖拽 store——指针每帧变化只重算本浮层，不牵动 ContentView/工具栏
  private struct TabDragGhostOverlay: View {
    @EnvironmentObject private var tabDragStore: TabDragStore
    /// 本浮层的全局帧（指针全局坐标换算本层位置用）
    @State private var myGlobalFrame: CGRect = .zero

    var body: some View {
      Group {
        if let dragging = tabDragStore.draggingTab, let pointer = tabDragStore.dragPointer,
          myGlobalFrame != .zero
        {
          ghostCard(tab: dragging.tab)
            // 左上角对齐鼠标（offset 相对 topLeading 摆位）：卡片不会盖住
            // 指针位置左侧与上方的标签栏信息
            .offset(
              x: pointer.x - myGlobalFrame.minX,
              y: pointer.y - myGlobalFrame.minY
            )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .allowsHitTesting(false)
      .background(
        GeometryReader { geo in
          Color.clear.onAppear { myGlobalFrame = geo.frame(in: .global) }
        }
      )
    }

    /// 浮起卡片：与原标签同形等宽（顶部圆角标签形 + 实测宽度复刻），
    /// 阴影浮起 + 轻微透明
    private func ghostCard(tab: EditorTab) -> some View {
      HStack(spacing: 8) {
        Image(systemName: tab.iconName)
          .font(.system(size: 11))
          .foregroundStyle(Color.accentColor)
        Text(tab.title)
          .font(.system(size: 13))
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 190, alignment: .leading)
          .fixedSize(horizontal: true, vertical: false)
      }
      // 内容区等宽复刻（扣除两侧内衬 5pt）：与原标签长度一致
      .frame(width: max((tabDragStore.ghostWidth ?? 0) - 10, 0), alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(
        TopRoundedRectangle(radius: 8)
          .fill(Color(nsColor: .windowBackgroundColor))
          .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
      )
      .overlay(
        TopRoundedRectangle(radius: 8)
          .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
      )
      .opacity(0.92)
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
    // 左右边栏均为自定义面板（HStack 自管宽度）：消融实验证实 NavigationSplitView
    // 的列宽协商层存在不可修的宽度振荡（拖面板时 ±10~100pt 的 4 值极限环）；
    // 系统检查器的拖拽又自带「拖过最窄即收起」，而需求是显隐只由按钮控制。
    // 宽度/显隐由 PanelLayoutStore 承载且宿主自观测——ContentView 与 .toolbar
    // 不随拖拽逐帧宽度重算（此前拖右栏会带着工具栏一起动的根因）
    HStack(spacing: 0) {
      SidebarPanelHost()
      tabArea
        .frame(minWidth: 360)
      DetailPanelHost()
    }
  }

  /// 左侧悬浮侧栏宿主：自观测 PanelLayoutStore（宽度/显隐变化只重排本栏）
  private struct SidebarPanelHost: View {
  @EnvironmentObject private var panels: PanelLayoutStore

  var body: some View {
    if panels.isFileSidebarPresented {
      FileTreeView()
        // 主色压白 + 可调透度：titlebar 材质(behindWindow)提供桌面透映，
        // 白色叠加层把主色拉回白、opacity 即透度旋钮（0.82 = 82% 白 +
        // 18% 桌面，用户反馈「微微透出」；改这一个数即可调）
        .background(
          ZStack {
            SidebarMaterialBackground()
              .ignoresSafeArea(edges: .top)
            Color.white.opacity(0.82)
          }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        .frame(width: panels.fileSidebarWidth)
        .frame(maxHeight: .infinity)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .trailing) {
          // 拖拽区覆盖面板右缘 ±6pt（落在右侧 10pt 外衬内）
          PanelDragStrip(
            width: $panels.fileSidebarWidth,
            clamp: PanelLayoutStore.clampedFileSidebarWidth,
            accessibilityLabel: "调整文件边栏宽度",
            onDragBegan: panels.beginResize,
            onDragEnded: panels.endResize
          )
          .frame(width: 12)
          .frame(maxHeight: .infinity)
          .padding(.trailing, 4)
        }
    }
  }
}

/// 右侧面板宿主（自定义，复刻系统检查器）：inspector 材质 + 左缘拖拽条
///（280–360 钳制）。拖拽永不触发收起——显隐只由工具栏按钮控制
private struct DetailPanelHost: View {
  @EnvironmentObject private var panels: PanelLayoutStore
  @StateObject private var transcriptScroll = AITranscriptScrollCoordinator()

  var body: some View {
    if panels.isDetailPanelPresented {
      ZStack {
        InspectorMaterialBackground()
        DetailPanelContent()
          .equatable()
          .environmentObject(transcriptScroll)
      }
      .frame(width: panels.detailPanelWidth)
      .frame(maxHeight: .infinity)
      .overlay(alignment: .leading) {
        Divider()
      }
      .overlay(alignment: .leading) {
        // 拖拽区以分界线为中心左右各探 6pt（offset -6 向左探出面板覆盖分界线本身，
        // 光标放在分界线上即可拖拽）：拖左增宽、拖右收窄（direction -1）
        PanelDragStrip(
          width: $panels.detailPanelWidth,
          direction: -1,
          clamp: PanelLayoutStore.clampedDetailPanelWidth,
          accessibilityLabel: "调整右侧面板宽度",
          onWidthCommitted: transcriptScroll.widthDidChange,
          onDragBegan: {
            panels.beginResize()
            transcriptScroll.beginResize()
          },
          onDragEnded: {
            panels.endResize()
            transcriptScroll.endResize()
          }
        )
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .offset(x: -6)
      }
    }
  }
}

/// 右侧面板内容不读取列宽。外层拖拽只改变布局提议，内容继续实时换行，
/// 但不会因为 PanelLayoutStore 每帧发布而重算整棵 SwiftUI body。
/// 自身的环境对象变化仍会独立触发更新。
private struct DetailPanelContent: View, Equatable {
  @EnvironmentObject private var workspaceStore: WorkspaceStore
  @EnvironmentObject private var tabStore: TabStore

  static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }

  var body: some View {
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
}

/// 左侧文件树收起/展开按钮（FR-1.1）：独立观测布局 store，点击不牵动 ContentView
private struct FileSidebarToggleButton: View {
  @EnvironmentObject private var panels: PanelLayoutStore

  var body: some View {
    Button {
      withAnimation(.easeOut(duration: 0.15)) {
        panels.isFileSidebarPresented.toggle()
      }
    } label: {
      Image(systemName: "sidebar.leading")
    }
    .help("显示/隐藏文件树")
  }
}

/// 右侧面板收起/展开按钮：自定义面板无系统拖动收起，显隐完全由此按钮控制
private struct DetailPanelToggleButton: View {
  @EnvironmentObject private var panels: PanelLayoutStore

  var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) {
        panels.isDetailPanelPresented.toggle()
      }
    } label: {
      Image(systemName: "sidebar.right")
        .symbolVariant(panels.isDetailPanelPresented ? .fill : .none)
    }
    .help(panels.isDetailPanelPresented ? "收起右侧面板" : "展开右侧面板")
  }
}

  /// 窗口工具栏（挂最外层 body，不随右栏拖拽/收放被挤动）
  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      // 左侧文件树收起/展开（FR-1.1）；按钮自观测布局 store，拖拽调宽不牵动工具栏
      FileSidebarToggleButton()
    }
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
      // 右侧面板整栏收起/展开（缩略图/大纲/AI 助手同栏）；按钮自观测布局 store
      DetailPanelToggleButton()
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

/// 窗口右缘的标签落点（拖标签到此处创建/移入最右侧组）：
/// 高亮跟随共享拖拽指针；落定逻辑在源栏手势 onEnded 里执行（无系统拖放会话，不设 onDrop）
private struct EdgeTabDropZone: View {
  @EnvironmentObject private var tabDragStore: TabDragStore
  @State private var myFrame: CGRect = .zero

  var body: some View {
    Color.clear
      .frame(width: 10)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
          .padding(4)
      )
      .background(
        // 上报本条的全局帧（源栏手势据此判定边缘落点）
        GeometryReader { geo in
          Color.clear
            .onAppear {
              myFrame = geo.frame(in: .global)
              tabDragStore.edgeDropFrame = myFrame
            }
            .onChange(of: geo.frame(in: .global)) { newFrame in
              myFrame = newFrame
              tabDragStore.edgeDropFrame = newFrame
            }
        }
      )
  }

  private var isTargeted: Bool {
    guard let pointer = tabDragStore.dragPointer else { return false }
    return myFrame.contains(pointer)
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
    .environmentObject(TabDragStore())
    .environmentObject(PanelLayoutStore())
    .environmentObject(PDFReaderStore())
    .environmentObject(PDFBookmarksStore())
    .environmentObject(WorkspaceStateStore())
}


/// 侧栏底材：titlebar 材质 + behindWindow——提供桌面透映（与右栏检查器
/// 同款机制）；主色/透度由面板上的白色叠加层（opacity 0.82）控制
private struct SidebarMaterialBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .titlebar
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 右侧面板底材：inspector 材质（运行时实测 rawValue 18）+ withinWindow——
/// 复刻系统检查器外观（透出窗口内内容而非桌面，见 MatProbe 对照结论）
private struct InspectorMaterialBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = NSVisualEffectView.Material(rawValue: 18) ?? .sidebar
    view.blendingMode = .withinWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 面板拖拽条（左右边栏共用）：按住水平拖动直写列宽，方向系数区分两侧——
/// 左栏拖右增宽（direction 1）；右栏拖左增宽（direction -1）。
/// 宽度由状态直接指定并钳制，无系统协商，拖不出显隐切换
private struct PanelDragStrip: NSViewRepresentable {
  @Binding var width: CGFloat
  /// 拖动方向系数：+1 拖右增宽（左栏）；-1 拖左增宽（右栏）
  var direction: CGFloat = 1
  /// 列宽钳制函数（各自栏的 min/max 范围）
  var clamp: (CGFloat) -> CGFloat
  var accessibilityLabel: String
  /// 列宽已按显示帧发布后的通知；右侧 AI transcript 用它同步滚动基准。
  var onWidthCommitted: () -> Void = {}
  /// 仅控制偏好持久化生命周期；不冻结列宽或内容换行。
  var onDragBegan: () -> Void
  var onDragEnded: () -> Void

  func makeNSView(context: Context) -> PanelDragStripNSView {
    let view = PanelDragStripNSView()
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.splitter)
    return view
  }

  func updateNSView(_ nsView: PanelDragStripNSView, context: Context) {
    nsView.currentWidth = width
    nsView.direction = direction
    nsView.setAccessibilityLabel(accessibilityLabel)
    nsView.onWidthChanged = { newWidth in
      let nextWidth = clamp(newWidth)
      guard abs(nextWidth - width) > 0.01 else { return }
      width = nextWidth
      onWidthCommitted()
    }
    nsView.onDragBegan = onDragBegan
    nsView.onDragEnded = onDragEnded
  }
}

final class PanelDragStripNSView: NSView {
  /// 当前列宽（SwiftUI 每轮同步；拖动起点）
  var currentWidth: CGFloat = 0
  /// 拖动方向系数（±1，见 PanelDragStrip）
  var direction: CGFloat = 1
  /// 拖动中目标列宽回调
  var onWidthChanged: ((CGFloat) -> Void)?
  var onDragBegan: (() -> Void)?
  var onDragEnded: (() -> Void)?
  private var dragStartX: CGFloat = 0
  private var dragStartWidth: CGFloat = 0
  /// 鼠标采样可能高于显示刷新率；每个显示帧只提交最新坐标，避免同一帧
  /// 重复排版。显示帧仍逐帧更新列宽，文字换行保持实时。
  private var pendingWidth: CGFloat?
  private var frameDisplayLink: CADisplayLink?
  private var isDragging = false

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func mouseDown(with event: NSEvent) {
    if isDragging { finishDrag() }
    dragStartX = event.locationInWindow.x
    dragStartWidth = currentWidth
    pendingWidth = nil
    isDragging = true
    onDragBegan?()
    startDisplayLink()
  }

  override func mouseDragged(with event: NSEvent) {
    pendingWidth = dragStartWidth + direction * (event.locationInWindow.x - dragStartX)
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    pendingWidth = dragStartWidth + direction * (event.locationInWindow.x - dragStartX)
    flushPendingWidth()
    finishDrag()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { finishDrag() }
    super.viewWillMove(toWindow: newWindow)
  }

  private func startDisplayLink() {
    stopDisplayLink()
    let link = displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
    // ProMotion 屏幕跟随实际刷新率；系统会自动钳制到当前显示器能力。
    // 每帧仍只提交最后一次鼠标采样，不会放大布局次数。
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    frameDisplayLink = link
  }

  private func stopDisplayLink() {
    frameDisplayLink?.invalidate()
    frameDisplayLink = nil
  }

  private func finishDrag() {
    stopDisplayLink()
    pendingWidth = nil
    guard isDragging else { return }
    isDragging = false
    onDragEnded?()
  }

  @objc private func displayLinkDidFire(_ link: CADisplayLink) {
    flushPendingWidth()
  }

  private func flushPendingWidth() {
    guard let width = pendingWidth else { return }
    pendingWidth = nil
    onWidthChanged?(width)
  }

  deinit {
    frameDisplayLink?.invalidate()
  }
}
