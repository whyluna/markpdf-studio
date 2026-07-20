import SwiftUI

/// 全文搜索面板（FR-6.2；⌘⇧F）：md 内容 + PDF 提取文本，结果带上下文预览，点击跳转命中处。
struct FullTextSearchView: View {
  @ObservedObject var store: SearchStore
  /// 工作区根路径（展示相对路径）
  let rootPath: String
  let onSelect: (FullTextSearchResult) -> Void
  let onDismiss: () -> Void

  @State private var selectedIndex = 0

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        CommandSearchField(
          text: $store.query,
          placeholder: "全文搜索（至少 2 个字符）…",
          onMoveUp: { selectedIndex = max(0, selectedIndex - 1) },
          onMoveDown: { selectedIndex = min(store.results.count - 1, selectedIndex + 1) },
          onSubmit: openSelected,
          onCancel: onDismiss
        )
        if store.isSearching {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      if store.results.isEmpty {
        Text(store.query.count >= 2 && !store.isSearching ? "无匹配内容" : "输入关键词搜索 md 与 PDF 内容")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(store.results.enumerated()), id: \.element.id) { index, result in
                resultRow(result, selected: index == selectedIndex)
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
    .frame(width: 560, height: 420)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
    .onChange(of: store.results) { _ in
      selectedIndex = 0
    }
  }

  private func resultRow(_ result: FullTextSearchResult, selected: Bool) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: result.kind.iconName)
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(result.url.lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(result.kind == .markdown ? "第 \(result.location) 行" : "第 \(result.location) 页")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Spacer(minLength: 4)
          Text("\(result.score) 处命中")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Text(result.snippet)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    .contentShape(RoundedRectangle(cornerRadius: 7))
  }

  private func openSelected() {
    guard store.results.indices.contains(selectedIndex) else { return }
    onSelect(store.results[selectedIndex])
  }
}

#Preview {
  FullTextSearchView(
    store: SearchStore(),
    rootPath: "/ws",
    onSelect: { _ in },
    onDismiss: {}
  )
}
