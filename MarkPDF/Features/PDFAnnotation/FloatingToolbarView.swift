import SwiftUI

/// 划词浮动工具条（FR-4.1）：高亮 / 下划线 / 删除线 / 波浪线。
/// 视觉对齐设计稿 .tbtn：28px 按钮、胶囊底、分隔线。
struct FloatingToolbarView: View {
  /// 当前颜色（预览点）
  let colorsByKind: [AnnotationKind: AnnotationColor]
  let onApply: (AnnotationKind) -> Void

  private static let tools: [(kind: AnnotationKind, icon: String)] = [
    (.highlight, "highlighter"),
    (.underline, "underline"),
    (.strikeOut, "strikethrough"),
    (.squiggly, "waveform.path"),
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
              .fill(colorsByKind[tool.kind]?.nsColor.swiftUI ?? .clear)
              .frame(width: 5, height: 5)
              .offset(x: 2, y: 2)
          }
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.kind.title)
        if tool.kind != Self.tools.last?.kind {
          Divider()
            .frame(height: 16)
        }
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
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
  FloatingToolbarView(
    colorsByKind: [
      .highlight: .yellow,
      .underline: .blue,
      .strikeOut: .red,
      .squiggly: .green,
    ],
    onApply: { _ in }
  )
  .padding(20)
}
