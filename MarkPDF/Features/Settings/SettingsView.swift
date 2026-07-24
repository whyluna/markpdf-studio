import AppKit
import SwiftUI

/// 设置面板（FR-7.2；⌘,）：通用（语言/编辑器/阅读/默认打开方式）+ AI（FR-AI.4）两个标签页。
struct SettingsView: View {
  @EnvironmentObject private var settings: SettingsStore
  @EnvironmentObject private var defaultHandler: DefaultHandlerService
  @State private var showLanguageRestartPrompt = false

  /// 开关绑定系统真实状态：开 = 设为默认（完成后重查）；关 = 无操作（macOS 无「取消默认」，回弹）
  private func defaultBinding(for kind: DefaultHandlerService.FileKind) -> Binding<Bool> {
    Binding(
      get: { kind == .markdown ? defaultHandler.isDefaultMarkdown : defaultHandler.isDefaultPDF },
      set: { isOn in
        if isOn {
          defaultHandler.setAsDefault(for: kind)
        } else {
          defaultHandler.refresh()
        }
      }
    )
  }

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
      Section("语言") {
        Picker("界面语言", selection: $settings.appLanguage) {
          ForEach(SettingsStore.AppLanguage.allCases) { language in
            Text(language.title).tag(language)
          }
        }
      }
      Section("编辑器") {
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
      }
      Section("阅读") {
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
      Section {
        Toggle("默认用 MarkPDF 打开 Markdown 文件", isOn: defaultBinding(for: .markdown))
        Toggle("默认用 MarkPDF 打开 PDF 文件", isOn: defaultBinding(for: .pdf))
      } header: {
        Text("默认打开方式")
      } footer: {
        Text("开关反映系统当前设置。改用其他 App 请在 Finder 中对文件「显示简介 → 打开方式」修改。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear { defaultHandler.refresh() }
    // 语言切换需重启：系统菜单由运行时按 AppleLanguages 提供，无法运行中切换
    .onChange(of: settings.appLanguage) { _, _ in
      showLanguageRestartPrompt = true
    }
    .alert("语言设置将在重启 App 后生效", isPresented: $showLanguageRestartPrompt) {
      Button("退出 App") { NSApp.terminate(nil) }
      Button("稍后", role: .cancel) {}
    }
  }
}

#Preview {
  SettingsView()
    .environmentObject(SettingsStore())
    .environmentObject(AISettingsStore())
    .environmentObject(AIKeyStore())
    .environmentObject(DefaultHandlerService())
}
