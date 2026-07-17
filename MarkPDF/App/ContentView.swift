import SwiftUI

/// 应用根视图：三栏布局（文件树 / 内容区 / 上下文面板）。
/// 中间内容区已接入 Markdown 编辑器内核；文件树（FR-1.1）与右侧面板为占位。
struct ContentView: View {
  @StateObject private var editorStore = EditorStore()
  @Environment(\.colorScheme) private var colorScheme

  private var editorTheme: MarkdownEditorView.EditorTheme {
    colorScheme == .dark ? .dark : .light
  }

  var body: some View {
    NavigationSplitView {
      // FR-1.1 工作区文件树（待实现）
      List {
        Label("papers", systemImage: "folder")
        Label("notes", systemImage: "folder")
        Label("assets", systemImage: "folder")
      }
      .navigationTitle("工作区")
      .frame(minWidth: 238)
    } content: {
      MarkdownEditorView(
        text: $editorStore.text,
        mode: editorStore.mode,
        theme: editorTheme,
        onContentChanged: { newText in
          editorStore.contentDidChange(newText)
        }
      )
      .frame(minWidth: 480)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker("编辑模式", selection: $editorStore.mode) {
            ForEach(MarkdownEditorView.EditorMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 260)
        }
      }
    } detail: {
      // 右侧面板：大纲 / 缩略图 / 标注（待实现）
      ContentPlaceholder(title: "面板", subtitle: "大纲 · 缩略图 · 标注")
        .frame(minWidth: 266)
    }
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
}
