import SwiftUI

/// 设置面板（FR-7.2；⌘,）：通用（编辑器/PDF/模式）+ AI（FR-AI.4）两个标签页。
struct SettingsView: View {
  @EnvironmentObject private var settings: SettingsStore

  var body: some View {
    TabView {
      generalSettings
        .tabItem { Label("通用", systemImage: "gearshape") }
      AISettingsView()
        .tabItem { Label("AI", systemImage: "sparkles") }
    }
    .frame(width: 500, height: 560)
  }

  private var generalSettings: some View {
    Form {
      Picker("编辑器字体", selection: $settings.editorFont) {
        ForEach(SettingsStore.EditorFont.allCases) { font in
          Text(font.title).tag(font)
        }
      }
      HStack {
        Text("字号")
        Slider(value: $settings.editorFontSize, in: 13...20, step: 0.5)
        Text("\(settings.editorFontSize, specifier: "%.1f")")
          .monospacedDigit()
          .frame(width: 36, alignment: .trailing)
      }
      HStack {
        Text("行高")
        Slider(value: $settings.editorLineHeight, in: 1.4...2.2, step: 0.1)
        Text("\(settings.editorLineHeight, specifier: "%.1f")")
          .monospacedDigit()
          .frame(width: 36, alignment: .trailing)
      }
      Picker("PDF 默认视图", selection: $settings.pdfViewMode) {
        ForEach(SettingsStore.PDFViewMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      // FR-3.6：阅读主题（白天/夜间）
      Picker("PDF 阅读主题", selection: $settings.pdfReadingTheme) {
        ForEach(SettingsStore.PDFReadingTheme.allCases) { theme in
          Text(theme.title).tag(theme)
        }
      }
      // FR-2.10：打字机/专注模式（可分别开关）
      Toggle("打字机模式（当前行居中）", isOn: $settings.typewriterMode)
      Toggle("专注模式（高亮当前段落）", isOn: $settings.focusMode)
    }
    .formStyle(.grouped)
    .padding()
  }
}

#Preview {
  SettingsView()
    .environmentObject(SettingsStore())
    .environmentObject(AISettingsStore())
    .environmentObject(AIKeyStore())
}
