import SwiftUI

/// 划词浮动工具条（FR-4.1）：高亮 / 下划线 / 删除线。
/// 视觉对齐设计稿 .tbtn：28px 按钮、胶囊底、分隔线。
/// 观察 Store：色板（FR-4.4）改动后按钮上的用色预览点实时同步。
struct FloatingToolbarView: View {
  @ObservedObject var store: PDFAnnotationStore
  let onApply: (AnnotationKind) -> Void
  @State private var hoveredKind: AnnotationKind?

  private static let tools: [(kind: AnnotationKind, icon: String)] = [
    (.highlight, "highlighter"),
    (.underline, "underline"),
    (.strikeOut, "strikethrough"),
    (.freeText, "text.bubble"),
  ]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Self.tools, id: \.kind) { tool in
        Button {
          onApply(tool.kind)
        } label: {
          ZStack(alignment: .bottomTrailing) {
            Image(systemName: tool.icon)
              .font(.system(size: 13))
              .foregroundStyle(.primary)
            Circle()
              .fill(store.colorsByKind[tool.kind]?.nsColor.swiftUI ?? .clear)
              .frame(width: 5, height: 5)
              .offset(x: 2, y: 2)
          }
          .frame(width: 28, height: 28)
          .background(
            hoveredKind == tool.kind ? Color.primary.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
          hoveredKind = hovering ? tool.kind : nil
        }
        .help(tool.kind.title)
        if tool.kind != Self.tools.last?.kind {
          Divider()
            .frame(height: 16)
        }
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
  }
}

private extension NSColor {
  var swiftUI: Color { Color(self) }
}

#Preview {
  FloatingToolbarView(store: PDFAnnotationStore(), onApply: { _ in })
    .padding(20)
}
