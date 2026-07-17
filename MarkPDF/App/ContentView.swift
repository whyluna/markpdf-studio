import SwiftUI

/// 应用根视图：三栏布局骨架（文件树 / 内容区 / 上下文面板）。
/// 当前为 M1 脚手架占位，按 PRD §6 设计稿（prototype/index.html）逐步实现。
struct ContentView: View {
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
      // 中间内容区：标签页 + Markdown/PDF 视图（待实现）
      ContentPlaceholder(
        title: "MarkPDF Studio",
        subtitle: "Markdown + PDF 阅读编辑工作台 · M1 脚手架"
      )
      .frame(minWidth: 480)
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
