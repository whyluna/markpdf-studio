import SwiftUI

/// 设置页 AI 分区（FR-AI.4）：Provider 管理（Keychain 密钥 + 连接测试）、
/// 划词翻译偏好（引擎 / 目标语言 / 自动触发）、AI 助手偏好（对话模型 / 三层上下文开关）。
struct AISettingsView: View {
  @EnvironmentObject private var aiSettings: AISettingsStore
  @EnvironmentObject private var aiKeys: AIKeyStore

  @State private var keyDrafts: [String: String] = [:]
  @State private var testStates: [String: ConnectionTestState] = [:]

  private enum ConnectionTestState: Equatable {
    case testing
    case success(String)
    case failure(String)
  }

  var body: some View {
    Form {
      Section("服务 Provider") {
        ForEach(AIProviderKind.allCases) { kind in
          providerRow(kind)
        }
      }
      Section("划词翻译") {
        Picker("翻译引擎", selection: settingsBinding(\.translationEngine)) {
          ForEach(AITranslationEngine.allCases) { engine in
            Text(engine.title).tag(engine)
          }
        }
        Picker("目标语言", selection: settingsBinding(\.targetLanguage)) {
          ForEach(AITargetLanguage.allCases) { language in
            Text(language.title).tag(language)
          }
        }
        Toggle("划词后自动翻译", isOn: settingsBinding(\.autoTranslateOnSelection))
      }
      Section("AI 助手") {
        chatProviderPicker
        Toggle("提问时附带选中文本", isOn: settingsBinding(\.contextIncludeSelection))
        Toggle("附带当前文档全文", isOn: settingsBinding(\.contextIncludeDocument))
        Toggle("检索工作区其他文件", isOn: settingsBinding(\.contextIncludeWorkspace))
      }
      Section {
        Text("AI 功能仅在你显式发起请求时，将所选内容发送至你配置的第三方服务；API Key 保存在系统钥匙串。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
  }

  // MARK: - Provider 行

  @ViewBuilder
  private func providerRow(_ kind: AIProviderKind) -> some View {
    DisclosureGroup {
      TextField("Base URL", text: configBinding(kind, \.baseURL))
      TextField("模型", text: configBinding(kind, \.model))
      HStack {
        SecureField(
          aiKeys.configuredAccounts.contains(kind.rawValue) ? String(localized: "API Key（已保存，输入以更换）") : String(localized: "API Key"),
          text: keyDraftBinding(for: kind)
        )
        Button("保存") {
          let key = keyDrafts[kind.rawValue] ?? ""
          guard !key.isEmpty else { return }
          aiKeys.save(key, for: kind.rawValue)
          keyDrafts[kind.rawValue] = ""
        }
        .disabled((keyDrafts[kind.rawValue] ?? "").isEmpty)
        if aiKeys.configuredAccounts.contains(kind.rawValue) {
          Button("清除") {
            aiKeys.remove(for: kind.rawValue)
          }
        }
      }
      HStack(spacing: 8) {
        Button("连接测试") {
          testConnection(kind)
        }
        .disabled(!aiKeys.configuredAccounts.contains(kind.rawValue) || testStates[kind.rawValue] == .testing)
        switch testStates[kind.rawValue] {
        case .testing:
          ProgressView()
            .controlSize(.small)
        case .success(let message):
          Text(message)
            .foregroundStyle(.green)
            .font(.callout)
        case .failure(let message):
          Text(message)
            .foregroundStyle(.red)
            .font(.callout)
            .lineLimit(2)
        case nil:
          EmptyView()
        }
      }
    } label: {
      Toggle(kind.title, isOn: enabledBinding(kind))
    }
  }

  // MARK: - 对话模型选择

  @ViewBuilder
  private var chatProviderPicker: some View {
    let enabled = AIProviderKind.allCases.filter { aiSettings.config(for: $0).isEnabled }
    if enabled.isEmpty {
      Text("先在上方启用并配置至少一个 Provider")
        .foregroundStyle(.secondary)
    } else {
      Picker("对话模型", selection: settingsBinding(\.chatProvider)) {
        ForEach(enabled) { kind in
          Text("\(kind.title) · \(aiSettings.config(for: kind).model)")
            .tag(kind.rawValue as String?)
        }
      }
    }
  }

  // MARK: - 连接测试

  private func testConnection(_ kind: AIProviderKind) {
    // 首次联网前隐私告知（FR-AI.4）；取消则不发任何请求
    guard AIPrivacyGate.ensureAcknowledged(store: aiSettings) else { return }
    testStates[kind.rawValue] = .testing
    let config = aiSettings.config(for: kind)
    let service = AIService(keys: aiKeys)
    Task { @MainActor in
      do {
        let elapsed = try await service.testConnection(kind: kind, config: config)
        testStates[kind.rawValue] = .success(String(format: String(localized: "连接正常（%.1fs）"), elapsed))
      } catch {
        testStates[kind.rawValue] = .failure(error.localizedDescription)
      }
    }
  }

  // MARK: - 绑定辅助

  private func settingsBinding<T>(_ keyPath: WritableKeyPath<AISettings, T>) -> Binding<T> {
    Binding(
      get: { aiSettings.settings[keyPath: keyPath] },
      set: { newValue in aiSettings.update { $0[keyPath: keyPath] = newValue } }
    )
  }

  private func configBinding(_ kind: AIProviderKind, _ keyPath: WritableKeyPath<AIProviderConfig, String>) -> Binding<String> {
    Binding(
      get: { aiSettings.config(for: kind)[keyPath: keyPath] },
      set: { newValue in aiSettings.updateConfig(kind) { $0[keyPath: keyPath] = newValue } }
    )
  }

  private func enabledBinding(_ kind: AIProviderKind) -> Binding<Bool> {
    Binding(
      get: { aiSettings.config(for: kind).isEnabled },
      set: { newValue in aiSettings.updateConfig(kind) { $0.isEnabled = newValue } }
    )
  }

  private func keyDraftBinding(for kind: AIProviderKind) -> Binding<String> {
    Binding(
      get: { keyDrafts[kind.rawValue] ?? "" },
      set: { keyDrafts[kind.rawValue] = $0 }
    )
  }
}

#Preview {
  AISettingsView()
    .environmentObject(AISettingsStore())
    .environmentObject(AIKeyStore())
    .frame(width: 500, height: 520)
}
