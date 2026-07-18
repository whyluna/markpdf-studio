import SwiftUI

/// 大纲面板（FR-2.6）：层级展示文档标题，点击跳转对应行。
/// 视觉对齐设计稿 `.oli`：H1 加粗、H2 起逐级缩进、次级文字色。
struct OutlinePanelView: View {
  let items: [Heading]
  let onSelect: (Heading) -> Void

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
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
              OutlineRow(item: item) {
                onSelect(item)
              }
            }
          }
          .padding(8)
        }
      }
    }
  }
}

private struct OutlineRow: View {
  let item: Heading
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(item.text)
        .font(.system(size: 13))
        .fontWeight(item.level == 1 ? .semibold : .regular)
        .foregroundStyle(item.level == 1 ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, CGFloat(item.level - 1) * 14)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

#Preview {
  OutlinePanelView(
    items: [
      Heading(level: 1, text: "系统对比", line: 1),
      Heading(level: 2, text: "卸载与预取", line: 8),
      Heading(level: 3, text: "LMCache", line: 12),
    ]
  ) { _ in }
  .frame(width: 266, height: 300)
}
