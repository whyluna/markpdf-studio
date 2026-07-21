import AppKit
import SwiftUI

/// 应用根视图：三栏布局（文件树 / 标签内容区 / 上下文面板）+ 底部状态栏。
/// 中间栏为标签组（FR-1.4）：单栏或左右分栏，每组含标签栏与激活标签内容。
struct ContentView: View {
  @EnvironmentObject private var workspaceStore: WorkspaceStore
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @EnvironmentObject private var annotationStore: PDFAnnotationStore
  @EnvironmentObject private var recentsStore: RecentFilesStore
  @EnvironmentObject private var stateStore: WorkspaceStateStore
  @EnvironmentObject private var searchStore: SearchStore
  @EnvironmentObject private var backlinksStore: BacklinksStore
  @EnvironmentObject private var imageStore: ImagePreviewStore

  var body: some View {
    VStack(spacing: 0) {
      splitView
      StatusBarView()
    }
    // 退出前兜底落盘（FR-2.7）：全部标签 + PDF 标注写回（FR-4.6 防抖窗口内退出不丢）+ 工作区快照（FR-1.6）
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      tabStore.flushAll()
      annotationStore.flushPendingWrites()
      stateStore.flush()
    }
    // 启动恢复现场（FR-1.6）与状态记录接线（FR-1.5/1.6）
    .onAppear {
      stateStore.restoreTabs(into: tabStore)
      stateStore.restoreWorkspace(into: workspaceStore)
      tabStore.onOpenFile = { url in
        guard let root = workspaceStore.root?.id else { return }
        recentsStore.record(url, forRoot: root)
      }
      tabStore.onStructureChange = { [weak tabStore] in
        guard let tabStore else { return }
        stateStore.tabsDidChange(groups: tabStore.groups, activeGroupID: tabStore.activeGroupID)
      }
      tabStore.onEditorCursorLine = { url, line in
        stateStore.recordCursor(url: url, line: line)
      }
      workspaceStore.onStateChange = { [weak workspaceStore] in
        stateStore.workspaceDidChange(
          root: workspaceStore?.root?.id,
          collapsedFolders: workspaceStore?.collapsedFolders ?? []
        )
        // 反向链接（FR-5.4）：工作区变化（含 FSEvents 刷新）后重扫，新引用 5s 内出现
        backlinksStore.setWorkspaceRoot(workspaceStore?.root?.id)
        backlinksStore.refresh()
      }
      // 全文搜索候选（FR-6.2）：工作区全部文件
      searchStore.filesProvider = { [weak workspaceStore] in
        workspaceStore?.allFiles.map(\.id) ?? []
      }
      // 反向链接候选（FR-5.4）：仅 md 文件
      backlinksStore.filesProvider = { [weak workspaceStore] in
        workspaceStore?.allFiles.filter { $0.kind == .markdown }.map(\.id) ?? []
      }
      backlinksStore.setWorkspaceRoot(workspaceStore.root?.id)
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

  // MARK: - 三栏布局

  private var splitView: some View {
    NavigationSplitView {
      // FR-1.1 工作区文件树
      FileTreeView()
        .frame(minWidth: 238)
    } content: {
      tabArea
        .frame(minWidth: 480)
        .toolbar {
          ToolbarItem(placement: .principal) {
            if tabStore.activeGroup.activeTab?.kind == .pdf {
              // PDF 标注工具组（FR-4.4，对齐设计稿 #pdfTools）
              PDFToolsView()
            } else if let store = tabStore.activeEditorStore {
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
            // 分栏切换（FR-1.4；设计稿 #btnSplit）
            Button {
              tabStore.toggleSplit()
            } label: {
              Image(systemName: tabStore.isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .help(tabStore.isSplit ? "合并为单栏" : "左右分栏")
          }
        }
    } detail: {
      detailPanel
    }
  }

  /// 右侧面板：pdf 标签 = 缩略图/书签/标注/引用（FR-3.3/5.4）；其余 = 大纲（FR-2.6）+ 反向链接（FR-5.4）
  @ViewBuilder
  private var detailPanel: some View {
    if let tab = tabStore.activeGroup.activeTab, tab.kind == .pdf, let url = tab.url {
      PDFSidebarView(url: url)
        .frame(minWidth: 266)
    } else {
      VStack(spacing: 0) {
        OutlinePanelView(items: tabStore.activeEditorStore?.outline ?? []) { heading in
          tabStore.activeEditorStore?.scrollTo(line: heading.line)
        }
        .frame(maxHeight: .infinity)
        BacklinksPanelView(target: tabStore.activeGroup.activeTab?.url)
          .frame(maxHeight: .infinity)
      }
      .frame(minWidth: 266)
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
    MarkdownExportFlow.run(format, store: store)
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
    commands.append(AppCommand(id: "open-folder", title: "打开文件夹…", section: "文件", shortcut: "⌘⇧O") {
      workspaceStore.openFolderPanel()
    })
    commands.append(AppCommand(id: "new-md", title: "新建 Markdown 文件", section: "文件", isEnabled: { hasWorkspace }) {
      _ = workspaceStore.createMarkdown(in: workspaceStore.root!.id, undo: nil)  // root 已由 isEnabled 保证
    })
    commands.append(AppCommand(id: "new-folder", title: "新建文件夹", section: "文件", isEnabled: { hasWorkspace }) {
      _ = workspaceStore.createFolder(in: workspaceStore.root!.id, undo: nil)
    })
    commands.append(AppCommand(id: "save", title: "保存", section: "文件", shortcut: "⌘S", isEnabled: { tabStore.activeEditorStore != nil }) {
      tabStore.activeEditorStore?.flushPendingSave()
    })
    commands.append(AppCommand(id: "quick-open", title: "快速打开…", section: "文件", shortcut: "⌘P", isEnabled: { hasWorkspace }) {
      workspaceStore.isQuickOpenPresented = true
    })
    commands.append(AppCommand(id: "full-search", title: "全文搜索…", section: "文件", shortcut: "⌘⇧F", isEnabled: { hasWorkspace }) {
      workspaceStore.isFullTextSearchPresented = true
    })

    // 导出
    commands.append(AppCommand(id: "export-pdf", title: "导出为 PDF", section: "导出", isEnabled: { canExportMarkdown }) {
      exportMarkdown(.pdf)
    })
    commands.append(AppCommand(id: "export-html", title: "导出为 HTML", section: "导出", isEnabled: { canExportMarkdown }) {
      exportMarkdown(.html)
    })
    commands.append(AppCommand(id: "export-annotations", title: "导出全部标注为 Markdown…", section: "导出", isEnabled: { canExportAnnotations }) {
      exportAnnotations()
    })

    // 视图
    commands.append(AppCommand(id: "split", title: tabStore.isSplit ? "合并为单栏" : "左右分栏", section: "视图") {
      tabStore.toggleSplit()
    })
    commands.append(AppCommand(id: "zoom-in", title: "放大", section: "视图", shortcut: "⌘=", isEnabled: { isPDF || isImage }) {
      if isPDF { pdfStore.zoomIn() } else { imageStore.zoomIn() }
    })
    commands.append(AppCommand(id: "zoom-out", title: "缩小", section: "视图", shortcut: "⌘-", isEnabled: { isPDF || isImage }) {
      if isPDF { pdfStore.zoomOut() } else { imageStore.zoomOut() }
    })
    commands.append(AppCommand(id: "zoom-reset", title: "实际大小", section: "视图", shortcut: "⌘0", isEnabled: { isPDF || isImage }) {
      if isPDF { pdfStore.resetZoom() } else { imageStore.resetZoom() }
    })
    for mode in MarkdownEditorView.EditorMode.allCases {
      commands.append(AppCommand(
        id: "mode-\(mode.rawValue)", title: "编辑模式：\(mode.title)", section: "视图",
        isEnabled: { tabStore.activeEditorStore != nil }
      ) {
        tabStore.activeEditorStore?.mode = mode
      })
    }

    // PDF
    commands.append(AppCommand(id: "find", title: "在文档中查找…", section: "PDF", shortcut: "⌘F", isEnabled: { isPDF }) {
      pdfStore.isFindBarVisible = true
    })
    commands.append(AppCommand(id: "find-next", title: "查找下一个", section: "PDF", shortcut: "⌘G", isEnabled: { pdfStore.isFindBarVisible }) {
      pdfStore.findNext()
    })
    commands.append(AppCommand(id: "find-prev", title: "查找上一个", section: "PDF", shortcut: "⇧⌘G", isEnabled: { pdfStore.isFindBarVisible }) {
      pdfStore.findPrevious()
    })
    commands.append(AppCommand(id: "copy-quote", title: "复制为带回链的引用", section: "PDF", shortcut: "⇧⌘C", isEnabled: { isPDF && pdfStore.hasSelection }) {
      PDFQuoteExporter.copyAsQuote(
        pdfView: pdfStore.pdfView,
        currentPage: pdfStore.currentPage,
        workspaceRoot: workspaceStore.root?.id
      )
    })
    commands.append(AppCommand(
      id: "sidecar",
      title: annotationStore.isSidecarMode ? "关闭只读标注模式" : "开启只读标注模式",
      section: "PDF",
      isEnabled: { annotationStore.currentFileURL != nil }
    ) {
      annotationStore.setSidecarMode(!annotationStore.isSidecarMode)
    })
    for kind in AnnotationKind.allCases {
      commands.append(AppCommand(
        id: "tool-\(kind.rawValue)", title: "标注工具：\(kind.title)", section: "PDF",
        isEnabled: { isPDF }
      ) {
        annotationStore.activeTool = kind
      })
    }

    // 其他
    commands.append(AppCommand(id: "settings", title: "设置…", section: "其他", shortcut: "⌘,") {
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
            pdfStore.pendingPage = result.location
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

/// 窗口右缘的标签落点：拖标签到此处创建/移入最右侧组
private struct EdgeTabDropZone: View {
  @EnvironmentObject private var tabStore: TabStore
  @State private var isTargeted = false

  var body: some View {
    Color.clear
      .frame(width: 28)
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
    .environmentObject(WorkspaceStore())
    .environmentObject(TabStore())
    .environmentObject(PDFReaderStore())
    .environmentObject(PDFBookmarksStore())
    .environmentObject(WorkspaceStateStore())
}
