import AppKit
import SwiftUI

/// 应用根视图：三栏布局（文件树 / 内容区 / 上下文面板）。
/// 中间栏按文件树选择分发：Markdown → 编辑器；PDF → 阅读器；图片 → 预览。
struct ContentView: View {
  @EnvironmentObject private var workspaceStore: WorkspaceStore
  @EnvironmentObject private var editorStore: EditorStore
  @Environment(\.colorScheme) private var colorScheme

  private var editorTheme: MarkdownEditorView.EditorTheme {
    colorScheme == .dark ? .dark : .light
  }

  var body: some View {
    NavigationSplitView {
      // FR-1.1 工作区文件树
      FileTreeView()
        .frame(minWidth: 238)
    } content: {
      middleContent
        .frame(minWidth: 480)
        .toolbar {
          ToolbarItem(placement: .navigation) {
            if showsEditor, let fileURL = editorStore.currentFileURL {
              HStack(spacing: 6) {
                Text(fileURL.lastPathComponent)
                  .font(.headline)
                  .foregroundStyle(.secondary)
                if editorStore.hasUnsavedChanges {
                  Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .help("有未落盘的改动")
                }
              }
            }
          }
          ToolbarItem(placement: .principal) {
            if showsEditor {
              Picker("编辑模式", selection: $editorStore.mode) {
                ForEach(MarkdownEditorView.EditorMode.allCases) { mode in
                  Text(mode.title).tag(mode)
                }
              }
              .pickerStyle(.segmented)
              .frame(width: 260)
            }
          }
        }
    } detail: {
      // 右侧面板：md 上下文 = 大纲（FR-2.6）；pdf 上下文 = 缩略图/书签/标注（阶段 6）
      if showsEditor {
        OutlinePanelView(items: editorStore.outline) { heading in
          editorStore.scrollTo(line: heading.line)
        }
        .frame(minWidth: 266)
      } else {
        ContentPlaceholder(title: "面板", subtitle: "缩略图 · 书签 · 标注")
          .frame(minWidth: 266)
      }
    }
    // 退出前兜底落盘（FR-2.7）
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      editorStore.flushPendingSave()
    }
    // 快速打开面板（FR-6.1 ⌘P）
    .overlay {
      if workspaceStore.isQuickOpenPresented {
        quickOpenOverlay
      }
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
          if node.kind == .markdown {
            editorStore.loadFile(node.id)
          }
          workspaceStore.isQuickOpenPresented = false
        },
        onDismiss: {
          workspaceStore.isQuickOpenPresented = false
        }
      )
      .padding(.top, 80)
    }
  }

  /// 中间栏内容：按选中文件类型分发
  @ViewBuilder
  private var middleContent: some View {
    if let node = workspaceStore.selection, node.kind == .pdf {
      PDFReaderView(url: node.id)
    } else if let node = workspaceStore.selection, node.kind == .image {
      ImagePreviewView(url: node.id)
    } else {
      // 无选择 / Markdown / 目录：显示编辑器
      MarkdownEditorView(
        text: $editorStore.text,
        documentID: editorStore.currentFileURL,
        mode: editorStore.mode,
        theme: editorTheme,
        scrollToLine: editorStore.pendingScrollLine,
        onContentChanged: { newText in
          editorStore.contentDidChange(newText)
        },
        onOutlineChanged: { items in
          editorStore.outline = items
        },
        onScrollHandled: {
          editorStore.didHandleScroll()
        }
      )
    }
  }

  /// 中间栏是否为编辑器（决定工具栏是否显示文件名与模式切换）
  private var showsEditor: Bool {
    guard let node = workspaceStore.selection else { return true }
    return node.kind != .pdf && node.kind != .image
  }
}

private struct ContentPlaceholder: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 8) {
      Text(title).font(.title2).bold()
      Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  ContentView()
    .environmentObject(WorkspaceStore())
    .environmentObject(EditorStore())
}
