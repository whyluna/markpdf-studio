import SwiftUI

/// 设置页 AI 分区（FR-AI.4）：Provider 管理（Keychain 密钥 + 连接测试）、
/// 划词翻译偏好（引擎 / 目标语言 / 自动触发）、AI 助手偏好（对话模型 / 三层上下文开关）。
struct AISettingsView: View {
  @EnvironmentObject private var aiSettings: AISettingsStore
  @EnvironmentObject private var aiKeys: AIKeyStore

  @State private var keyDrafts: [String: String] = [:]
  @State private var modelDrafts: [String: String] = [:]
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
        if aiSettings.settings.translationEngine == .ai {
          modelPicker(
            title: String(localized: "翻译模型"),
            selection: settingsBinding(\.translationModel),
            nilLabel: String(localized: "跟随对话模型")
          )
        }
        Picker("目标语言", selection: settingsBinding(\.targetLanguage)) {
          ForEach(AITargetLanguage.allCases) { language in
            Text(language.title).tag(language)
          }
        }
        Toggle("划词后自动翻译", isOn: settingsBinding(\.autoTranslateOnSelection))
      }
      Section("AI 助手") {
        modelPicker(
          title: String(localized: "对话模型"),
          selection: settingsBinding(\.chatModel),
          nilLabel: String(localized: "自动（第一个可用）")
        )
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
      TextField("模型（多个用逗号分隔）", text: modelsBinding(kind))
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

  // MARK: - 模型选择（对话 / 翻译共用：全部启用 Provider × 模型列表）

  @ViewBuilder
  private func modelPicker(title: String, selection: Binding<AIModelChoice?>, nilLabel: String) -> some View {
    let choices: [AIModelChoice] = AIProviderKind.allCases.flatMap { kind -> [AIModelChoice] in
      let config = aiSettings.config(for: kind)
      guard config.isEnabled else { return [] }
      return config.models.map { AIModelChoice(provider: kind.rawValue, model: $0) }
    }
    if choices.isEmpty {
      Text("先在上方启用并配置至少一个 Provider")
        .foregroundStyle(.secondary)
    } else {
      Picker(title, selection: selection) {
        Text(nilLabel).tag(AIModelChoice?.none)
        ForEach(choices, id: \.self) { choice in
          Text("\(AIProviderKind(rawValue: choice.provider)?.title ?? choice.provider) · \(choice.model)")
            .tag(choice as AIModelChoice?)
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
        let elapsed = try await service.testConnection(kind: kind, config: config, model: config.models.first ?? "")
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

  /// 模型列表编辑：TextField 显示草稿原文（否则输入逗号途中被规范化回读吃掉），
  /// 每次变化把切分去空后的列表持久化
  private func modelsBinding(_ kind: AIProviderKind) -> Binding<String> {
    Binding(
      get: { modelDrafts[kind.rawValue] ?? aiSettings.config(for: kind).models.joined(separator: ", ") },
      set: { newValue in
        modelDrafts[kind.rawValue] = newValue
        let models = newValue
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        aiSettings.updateConfig(kind) { $0.models = models }
      }
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
