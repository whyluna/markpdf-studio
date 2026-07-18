import SwiftUI

/// 快速打开面板（FR-6.1）：文件名模糊搜索，↑↓ 导航、Enter 打开、Esc 关闭。
struct QuickOpenView: View {
  /// 候选文件（扁平化、仅文件）
  let files: [FileNode]
  /// 工作区根路径（展示相对路径）
  let rootPath: String
  let onSelect: (FileNode) -> Void
  let onDismiss: () -> Void

  @State private var query = ""
  @State private var selectedIndex = 0

  private static let maxResults = 50

  private var results: [FileNode] {
    if query.isEmpty {
      return Array(files.prefix(Self.maxResults))
    }
    return
      files
      .compactMap { node in
        FuzzyMatcher.match(query: query, in: node.name).map { (node, $0.score) }
      }
      .sorted { $0.1 > $1.1 }
      .prefix(Self.maxResults)
      .map(\.0)
  }

  var body: some View {
    VStack(spacing: 0) {
      CommandSearchField(
        text: $query,
        placeholder: "搜索文件名…",
        onMoveUp: { selectedIndex = max(0, selectedIndex - 1) },
        onMoveDown: { selectedIndex = min(results.count - 1, selectedIndex + 1) },
        onSubmit: openSelected,
        onCancel: onDismiss
      )
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      if results.isEmpty {
        Text("无匹配文件")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(results.enumerated()), id: \.element.id) { index, node in
                resultRow(node, selected: index == selectedIndex)
                  .id(index)
                  .onTapGesture {
                    selectedIndex = index
                    openSelected()
                  }
              }
            }
            .padding(6)
          }
          .onChange(of: selectedIndex) { index in
            proxy.scrollTo(index, anchor: .center)
          }
        }
      }
    }
    .frame(width: 520, height: 380)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
    .onChange(of: query) { _ in
      selectedIndex = 0
    }
  }

  private func resultRow(_ node: FileNode, selected: Bool) -> some View {
    HStack(spacing: 8) {
      Image(systemName: node.iconName)
        .foregroundStyle(selected ? Color.accentColor : .secondary)
      Text(node.name)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text(relativePath(of: node))
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.head)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    .contentShape(RoundedRectangle(cornerRadius: 7))
  }

  private func relativePath(of node: FileNode) -> String {
    let path = node.id.deletingLastPathComponent().path
    guard path.hasPrefix(rootPath) else { return path }
    let rel = String(path.dropFirst(rootPath.count))
    return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
  }

  private func openSelected() {
    guard results.indices.contains(selectedIndex) else { return }
    onSelect(results[selectedIndex])
  }
}

#Preview {
  QuickOpenView(
    files: [
      FileNode(id: URL(fileURLWithPath: "/ws/notes/a.md"), name: "a.md", kind: .markdown),
      FileNode(id: URL(fileURLWithPath: "/ws/papers/vllm.pdf"), name: "vllm.pdf", kind: .pdf),
    ],
    rootPath: "/ws",
    onSelect: { _ in },
    onDismiss: {}
  )
}
