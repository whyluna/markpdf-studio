import SwiftUI

/// 点选删除按钮（FR-4.5 前置交互）：光标旁小胶囊，
/// 整框可点（不只图标）、悬停加深背景、手型光标。
struct DeleteButtonView: View {
  let onDelete: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onDelete) {
      Image(systemName: "trash")
        .font(.system(size: 12))
        .foregroundStyle(.red)
        .frame(width: 26, height: 24)
        .background(
          isHovered ? Color.primary.opacity(0.1) : Color.clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovered = hovering
      // 光标由容器 HandCursorHostingView 的 cursorRect 统一管理
    }
    .padding(3)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
  }
}

#Preview {
  DeleteButtonView(onDelete: {})
    .padding(20)
}
