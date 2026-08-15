import SwiftUI

/// 划词浮动工具条（FR-4.1）：高亮 / 下划线 / 删除线。
/// 视觉对齐设计稿 .tbtn：28px 按钮、胶囊底、分隔线。
/// 观察 Store：色板（FR-4.4）改动后按钮上的用色预览点实时同步。
struct FloatingToolbarView: View {
  @ObservedObject var store: PDFAnnotationStore
  let onApply: (AnnotationKind) -> Void
  /// 划词翻译（FR-AI.1）：手动触发入口；自动触发关闭时尤为必要
  let onTranslate: () -> Void
  @State private var hoveredKind: AnnotationKind?
  @State private var isTranslateHovered = false

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
        Divider()
          .frame(height: 16)
      }
      Button(action: onTranslate) {
        Image(systemName: "translate")
          .font(.system(size: 13))
          .foregroundStyle(.primary)
          .frame(width: 28, height: 28)
          .background(
            isTranslateHovered ? Color.primary.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { isTranslateHovered = $0 }
      .help("翻译选中内容")
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

/// 划词浮动面板（FR-4.1 + FR-AI.1）：工具条在上，翻译气泡紧贴其下
struct SelectionFloatingPanel: View {
  @ObservedObject var store: PDFAnnotationStore
  @ObservedObject var translationStore: TranslationStore
  let onApply: (AnnotationKind) -> Void
  let onTranslate: () -> Void

  var body: some View {
    VStack(spacing: 6) {
      FloatingToolbarView(store: store, onApply: onApply, onTranslate: onTranslate)
      TranslationBubbleView(store: translationStore) {
        onTranslate()
      }
    }
    // 系统翻译引擎：Store 发出 Configuration 即触发，结果经 performSystemTranslation 写回。
    // 修改器挂在面板根部（稳定位置、始终安装）——此前挂在气泡的相位条件分支内，
    // 每次相位变化拆除重建子树，SwiftUI 更新事务被打断，UI 停在「翻译中」不再刷新。
    // 触发时的 Configuration 一并回传：语言对切换后旧配置的迟到回调凭此识别并忽略
    .translationTask(translationStore.systemConfiguration) { [configuration = translationStore.systemConfiguration] session in
      await translationStore.performSystemTranslation(using: session, configuration: configuration)
    }
  }
}

#Preview {
  FloatingToolbarView(store: PDFAnnotationStore(), onApply: { _ in }, onTranslate: {})
    .padding(20)
}
