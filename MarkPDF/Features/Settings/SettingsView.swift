import SwiftUI

/// 设置面板（FR-7.2；⌘,）：编辑器字体/字号/行高、PDF 默认视图模式。
struct SettingsView: View {
  @EnvironmentObject private var settings: SettingsStore

  var body: some View {
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
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .padding()
  }
}

#Preview {
  SettingsView()
    .environmentObject(SettingsStore())
}
