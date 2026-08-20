import PDFKit
import SwiftUI

/// 页边批注卡片（FR-4.3 视觉升级）：常驻显示批注文本，替代「点图标才见内容」。
/// 几何在页空间（跟随页面缩放），hosting 显示时按当前 scaleFactor 换算 frame 并
/// 同步字号/边距（尺寸量 × scale）。不透明底盖住 22pt 原生 /Text 图标——
/// 数据仍存 marker.contents，导出后第三方阅读器看到的标准便签批注不受影响。
struct CommentCardView: View {
  let text: String
  let color: NSColor
  /// 贴左页边（内容在右）→ 色条在右缘；贴右页边 → 色条在左缘（色条面向所指内容）
  let isLeftMargin: Bool
  /// 当前显示缩放：页空间字号 9.5pt 随页面同步缩放
  let scale: CGFloat
  /// 卡片显示宽度（视图单位；nil = 芯片形态自适应宽度）
  let width: CGFloat?
  let onClick: () -> Void

  @State private var isHovered = false

  private var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    Group {
      if isEmpty || width == nil {
        chip
      } else {
        card
      }
    }
    .onTapGesture(perform: onClick)
    .onHover { isHovered = $0 }
  }

  // MARK: - 卡片

  private var card: some View {
    Text(text)
      .font(.system(size: 8.5 * scale))
      .foregroundStyle(.primary)
      .lineLimit(6)
      .truncationMode(.tail)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: width, alignment: .topLeading)
      .padding(.horizontal, paddingH)
      .padding(.vertical, paddingV)
      .background(Color(nsColor: .controlBackgroundColor))
      .background(alignment: isLeftMargin ? .trailing : .leading) {
        // 色板色竖条：贴内容一侧的边缘，与虚线指认同向
        Rectangle().fill(Color(color)).frame(width: 2.5 * scale)
      }
      .clipShape(RoundedRectangle(cornerRadius: 5 * scale))
      .overlay(
        RoundedRectangle(cornerRadius: 5 * scale)
          .strokeBorder(Color.primary.opacity(isHovered ? 0.28 : 0.14), lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.12), radius: 2.5 * scale, y: scale)
      .contentShape(RoundedRectangle(cornerRadius: 5 * scale))
  }

  // MARK: - 芯片（空批注 / 窄边距文档）

  private var chip: some View {
    Image(systemName: "text.bubble")
      .font(.system(size: 10 * scale, weight: .medium))
      .foregroundStyle(Color(color))
      .padding(.horizontal, 4 * scale)
      .padding(.vertical, 3 * scale)
      // 完整盖住底下仍保持标准可见的 22pt /Text 图标；PDF 数据不再写 NoView。
      .frame(minWidth: 22 * scale, minHeight: 22 * scale)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
      .overlay(
        RoundedRectangle(cornerRadius: 4 * scale)
          .strokeBorder(Color.primary.opacity(isHovered ? 0.28 : 0.14), lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.12), radius: 2 * scale, y: scale)
      .contentShape(RoundedRectangle(cornerRadius: 4 * scale))
  }

  private var paddingH: CGFloat { 4.5 * scale }
  private var paddingV: CGFloat { 4 * scale }
}

#Preview("卡片") {
  VStack(alignment: .leading, spacing: 12) {
    CommentCardView(
      text: "此处需对比常识部分：农民与土地是职业与生产资料的对应关系，选项里只有工人与机器同构。",
      color: .systemBlue,
      isLeftMargin: false,
      scale: 1.0,
      width: 96,
      onClick: {}
    )
    CommentCardView(
      text: "答案存疑，复查类比推理一节",
      color: .systemOrange,
      isLeftMargin: true,
      scale: 1.4,
      width: 120,
      onClick: {}
    )
    HStack(spacing: 8) {
      CommentCardView(text: "", color: .systemBlue, isLeftMargin: false, scale: 1.0, width: nil, onClick: {})
      CommentCardView(text: "长批注但边距过窄", color: .systemGreen, isLeftMargin: false, scale: 1.0, width: nil, onClick: {})
    }
  }
  .padding(16)
  .frame(width: 260)
}
