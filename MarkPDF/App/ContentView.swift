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
      // 右侧面板：大纲 / 缩略图 / 标注（待实现）
      ContentPlaceholder(title: "面板", subtitle: "大纲 · 缩略图 · 标注")
        .frame(minWidth: 266)
    }
    .onChange(of: workspaceStore.selection) { node in
      guard let node, node.kind == .markdown else { return }
      editorStore.loadFile(node.id)
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
        onContentChanged: { newText in
          editorStore.contentDidChange(newText)
        }
      )
    }
  }

  /// 中间栏是否为编辑器（决定工具栏是否显示模式切换）
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
