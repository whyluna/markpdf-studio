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

  var body: some View {
    VStack(spacing: 0) {
      splitView
      StatusBarView()
    }
    // 退出前兜底落盘（FR-2.7）：全部标签 + PDF 标注写回（FR-4.6 防抖窗口内退出不丢）
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      tabStore.flushAll()
      annotationStore.flushPendingWrites()
    }
    // 最近打开记录接线（FR-1.5）：文件打开 → 按当前工作区根路径记录
    .onAppear {
      tabStore.onOpenFile = { url in
        guard let root = workspaceStore.root?.id else { return }
        recentsStore.record(url, forRoot: root)
      }
    }
    // 快速打开面板（FR-6.1 ⌘P）
    .overlay {
      if workspaceStore.isQuickOpenPresented {
        quickOpenOverlay
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
            // 导出菜单（设计稿 #btnExport）：PDF/HTML 导出为 FR-2.9 占位
            Menu {
              Button("导出为 PDF") {}
                .disabled(true)
              Button("导出为 HTML") {}
                .disabled(true)
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

  /// 右侧面板：pdf 标签 = 缩略图/书签/标注（FR-3.3）；其余 = 大纲（FR-2.6）
  @ViewBuilder
  private var detailPanel: some View {
    if let tab = tabStore.activeGroup.activeTab, tab.kind == .pdf, let url = tab.url {
      PDFSidebarView(url: url)
        .frame(minWidth: 266)
    } else {
      OutlinePanelView(items: tabStore.activeEditorStore?.outline ?? []) { heading in
        tabStore.activeEditorStore?.scrollTo(line: heading.line)
      }
      .frame(minWidth: 266)
    }
  }

  // MARK: - 导出（FR-4.8）

  /// 当前可导出标注：激活标签为 PDF 且标注 Store 已关联文档
  private var canExportAnnotations: Bool {
    tabStore.activeGroup.activeTab?.kind == .pdf && annotationStore.currentFileURL != nil
  }

  /// 导出当前 PDF 的全部标注到目标笔记，并在新标签中打开该笔记
  private func exportAnnotations() {
    guard let url = AnnotationExportFlow.run(store: annotationStore) else { return }
    tabStore.open(url: url)
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
}
