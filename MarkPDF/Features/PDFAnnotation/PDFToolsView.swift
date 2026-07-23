import SwiftUI

/// 窗口工具栏 PDF 标注工具组（FR-4.4，对齐设计稿 #pdfTools）：
/// 标注工具按钮（高亮/下划线/删除线 = 划词即标；批注 = 划词在页边插批注框）+
/// 四色色板（按类型记忆最近用色）。
struct PDFToolsView: View {
  @EnvironmentObject private var store: PDFAnnotationStore
  @EnvironmentObject private var aiSettings: AISettingsStore
  @State private var hoveredTool: AnnotationKind?
  @State private var hoveredColor: AnnotationColor?
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
        toolButton(tool.kind, icon: tool.icon)
      }
      translateToggle
      Divider()
        .frame(height: 20)
        .padding(.horizontal, 4)
      ForEach(AnnotationColor.allCases) { color in
        colorDot(color)
      }
    }
  }

  /// 划词翻译开关（FR-AI.1）：开启后划词即翻；关闭时选中文本点浮动工具条翻译按钮手动翻译。
  /// 状态即 设置 → AI 的「划词后自动翻译」（持久化，两处一致）
  private var translateToggle: some View {
    let isOn = aiSettings.settings.autoTranslateOnSelection
    return Button {
      aiSettings.update { $0.autoTranslateOnSelection.toggle() }
      if !isOn {
        // 开启翻译时退出标注工具（划词即标与划词即翻语义互斥）
        store.activeTool = nil
      }
    } label: {
      Image(systemName: "translate")
        .font(.system(size: 14))
        .foregroundStyle(isOn ? Color.accentColor : .secondary)
        .frame(width: 28, height: 28)
        .background(
          isOn
            ? Color.accentColor.opacity(0.15)
            : (isTranslateHovered ? Color.primary.opacity(0.08) : Color.clear),
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isTranslateHovered = $0 }
    .help(isOn
      ? "划词翻译（已开启：划词即翻；点击关闭）"
      : "划词翻译（已关闭：选中文本后点浮动条翻译按钮手动翻译；点击开启划词即翻）")
  }

  private func toolButton(_ kind: AnnotationKind, icon: String) -> some View {
    let isActive = store.activeTool == kind
    return Button {
      if isActive {
        store.activeTool = nil
      } else {
        store.activeTool = kind
        store.paletteKind = kind
        // 工具互斥（含翻译）：激活标注工具时退出划词即翻
        aiSettings.update { $0.autoTranslateOnSelection = false }
      }
    } label: {
      Image(systemName: icon)
        .font(.system(size: 14))
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
        .frame(width: 28, height: 28)
        .background(
          isActive
            ? Color.accentColor.opacity(0.15)
            : (hoveredTool == kind ? Color.primary.opacity(0.08) : Color.clear),
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      hoveredTool = hovering ? kind : nil
    }
    .help(isActive ? "\(kind.title)（已激活，划词即标注；再次点击退出）" : kind.title)
  }

  private func colorDot(_ color: AnnotationColor) -> some View {
    let isOn = store.colorsByKind[store.paletteKind] == color
    return Button {
      store.remember(color: color, for: store.paletteKind)
    } label: {
      Circle()
        .fill(color.nsColor.swiftUI)
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
          in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      hoveredColor = hovering ? color : nil
    }
    .help("\(store.paletteKind.title)用色")
  }
}

private extension NSColor {
  var swiftUI: Color { Color(self) }
}

#Preview {
  PDFToolsView()
    .environmentObject(PDFAnnotationStore())
    .environmentObject(AISettingsStore())
    .padding(20)
}
