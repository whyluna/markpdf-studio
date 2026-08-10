import SwiftUI

/// 点选标注的编辑条（FR-4.4/4.5）：光标旁小胶囊——
/// 文本标记类（高亮/下划线/删除线）给四色改色 + 删除；其余只给删除。
/// 色板样式与顶部工具栏一致（PDFToolsView.colorDot）；整框可点、悬停加深、手型光标
struct AnnotationEditBarView: View {
  /// 当前色（nil = 该标注不支持改色，只显示删除）
  let currentColor: AnnotationColor?
  let onPick: (AnnotationColor) -> Void
  let onDelete: () -> Void

  @State private var hoveredColor: AnnotationColor?
  @State private var isDeleteHovered = false

  var body: some View {
    HStack(spacing: 2) {
      if let currentColor {
        ForEach(AnnotationColor.allCases) { color in
          colorDot(color, isOn: color == currentColor)
        }
        Divider()
          .frame(height: 16)
          .padding(.horizontal, 2)
      }
      deleteButton
    }
    .padding(3)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
  }

  private func colorDot(_ color: AnnotationColor, isOn: Bool) -> some View {
    Button {
      onPick(color)
    } label: {
      Circle()
        .fill(Color(color.nsColor))
        .frame(width: 14, height: 14)
        .overlay(
          Circle()
            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .padding(2)
        .overlay(
          Circle()
            .strokeBorder(isOn ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .frame(width: 20, height: 20)
        .background(
          hoveredColor == color ? Color.primary.opacity(0.08) : Color.clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      hoveredColor = hovering ? color : nil
    }
  }

  private var deleteButton: some View {
    Button(action: onDelete) {
      Image(systemName: "trash")
        .font(.system(size: 12))
        .foregroundStyle(.red)
        .frame(width: 26, height: 24)
        .background(
          isDeleteHovered ? Color.primary.opacity(0.1) : Color.clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isDeleteHovered = hovering
      // 光标由容器 HandCursorHostingView 的 cursorRect 统一管理
    }
  }
}

#Preview {
  VStack(spacing: 12) {
    AnnotationEditBarView(currentColor: .yellow, onPick: { _ in }, onDelete: {})
    AnnotationEditBarView(currentColor: nil, onPick: { _ in }, onDelete: {})
  }
  .padding(20)
}
