import SwiftUI

/// 大纲面板（FR-2.6）：层级展示文档标题，点击跳转对应行。
/// 视觉对齐设计稿 `.oli`：H1 加粗、H2 起逐级缩进、次级文字色。
/// 当前节：光标所在小节高亮（accent 底），并随光标移动滚到可见。
/// 直接订阅 EditorStore：嵌套 ObservableObject 的 @Published 不向上冒泡，
/// 由父视图读值传入会导致光标移动不触发重算（实测要点两次正文大纲才跟）
struct OutlinePanelView: View {
  @ObservedObject var store: EditorStore
  let onSelect: (Heading) -> Void

  private var items: [Heading] { store.outline }

  /// 光标所属小节：最后一个起始行 ≤ 光标行的标题
  private var activeID: Int? {
    ActiveSection.index(positions: items.map(\.line), current: store.currentLine).map { items[$0].id }
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("大纲")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      Divider()
      if items.isEmpty {
        Text("文档中没有标题")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(items) { item in
                OutlineRow(item: item, isActive: item.id == activeID) {
                  onSelect(item)
                }
              }
            }
            .padding(8)
          }
          // 当前节跟随：光标移动时把激活项滚到可见（anchor: nil 最小滚动不惊扰）
          .onChange(of: activeID) { _, activeID in
            guard let activeID else { return }
            withAnimation(.easeOut(duration: 0.15)) {
              proxy.scrollTo(activeID)
            }
          }
        }
      }
    }
  }
}

private struct OutlineRow: View {
  let item: Heading
  let isActive: Bool
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(item.text)
        .font(.system(size: 13))
        .fontWeight(isActive || item.level == 1 ? .semibold : .regular)
        .foregroundStyle(isActive ? Color.accentColor : (item.level == 1 ? .primary : .secondary))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, CGFloat(item.level - 1) * 14)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          isActive
            ? Color.accentColor.opacity(0.12)
            : (isHovered ? Color.primary.opacity(0.05) : Color.clear),
          in: RoundedRectangle(cornerRadius: 6)
        )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

#Preview {
  let store = EditorStore()
  return OutlinePanelView(store: store) { _ in }
    .frame(width: 266, height: 300)
}
