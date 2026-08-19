import SwiftUI

/// 设置页 AI 分区（FR-AI.4）：Provider 管理（Keychain 密钥 + 连接测试）、
/// 划词翻译偏好（引擎 / 目标语言 / 自动触发）、AI 助手偏好（对话模型 / 三层上下文开关）。
struct AISettingsView: View {
  @EnvironmentObject private var aiSettings: AISettingsStore
  @EnvironmentObject private var aiKeys: AIKeyStore

  @State private var keyDrafts: [String: String] = [:]
  @State private var testStates: [String: ConnectionTestState] = [:]
  /// 展开编辑中的自定义 Provider id
  @State private var expandedCustomID: String?
  /// 模型名/窗口框焦点（回车与点击背景显式退出，光标不再滞留闪烁）
  @FocusState private var focusedModelField: String?

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
      Section("自定义 Provider") {
        ForEach(aiSettings.settings.customProviders) { provider in
          customProviderRow(provider)
        }
        Button {
          expandedCustomID = aiSettings.addCustomProvider().id
        } label: {
          Label("添加自定义 Provider", systemImage: "plus.circle")
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
        TextField(
          "回复长度上限（tokens）",
          value: settingsBinding(\.chatMaxReplyTokens),
          format: .number.grouping(.never)
        )
        .help("问答请求的 max_tokens；超过模型窗口时自动夹取到窗口一半")
        TextField(
          "写作上限（tokens）",
          value: settingsBinding(\.writingMaxReplyTokens),
          format: .number.grouping(.never)
        )
        .help("写作模式专用的 max_tokens（与问答分开）：提案里的文件内容占同一额度，写大文件需要更大上限；超过模型窗口时自动夹取到窗口一半")
        Toggle("提问时附带选中文本", isOn: settingsBinding(\.contextIncludeSelection))
        Toggle("附带当前文档全文", isOn: settingsBinding(\.contextIncludeDocument))
        Toggle("检索工作区其他文件", isOn: settingsBinding(\.contextIncludeWorkspace))
      }
      Section {
        Text("AI 功能仅在你显式发起请求时，将所选内容发送至你配置的第三方服务；API Key 保存在本机应用容器内。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    // 点击表单空白处退出文本框焦点（macOS 默认不主动 resign，光标会一直闪）
    .onTapGesture { focusedModelField = nil }
    // 钥匙串写入失败（NFR-5：失败须用户可感知）
    .alert("钥匙串", isPresented: keyErrorPresented) {
      Button("好") { aiKeys.lastError = nil }
    } message: {
      Text(aiKeys.lastError ?? "")
    }
  }

  private var keyErrorPresented: Binding<Bool> {
    Binding(
      get: { aiKeys.lastError != nil },
      set: { if !$0 { aiKeys.lastError = nil } }
    )
  }

  // MARK: - Provider 行

  @ViewBuilder
  private func providerRow(_ kind: AIProviderKind) -> some View {
    DisclosureGroup {
      TextField("Base URL", text: configBinding(kind, \.baseURL))
      modelSpecsEditor(kind)
      HStack {
        SecureField(
          aiKeys.configuredAccounts.contains(kind.rawValue) ? String(localized: "API Key（已保存，输入以更换）") : String(localized: "API Key"),
          text: keyDraftBinding(for: kind.rawValue)
        )
        Button("保存") {
          let key = keyDrafts[kind.rawValue] ?? ""
          guard !key.isEmpty else { return }
          // 写入失败（锁屏等）保留草稿不清空，错误经 aiKeys.lastError 弹窗
          if aiKeys.save(key, for: kind.rawValue) {
            keyDrafts[kind.rawValue] = ""
          }
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
          testConnection(kind.identity)
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

  // MARK: - 自定义 Provider 行（v2.1）

  /// 自定义 Provider：名称 / 协议族 / Base URL / Key / 模型清单 / 删除
  @ViewBuilder
  private func customProviderRow(_ provider: AICustomProvider) -> some View {
    DisclosureGroup(isExpanded: Binding(
      get: { expandedCustomID == provider.id },
      set: { expandedCustomID = $0 ? provider.id : nil }
    )) {
      TextField("名称", text: customBinding(provider.id, \.name, default: ""))
      Picker("协议", selection: customBinding(provider.id, \.familyRaw, default: AIProtocolFamily.openAICompatible.rawValue)) {
        Text("OpenAI 兼容").tag(AIProtocolFamily.openAICompatible.rawValue)
        Text("Anthropic").tag(AIProtocolFamily.anthropic.rawValue)
      }
      TextField("Base URL", text: customBinding(provider.id, \.baseURL, default: ""))
        .font(.system(size: 12, design: .monospaced))
      HStack {
        SecureField(
          aiKeys.configuredAccounts.contains(provider.id) ? String(localized: "API Key（已保存，输入以更换）") : String(localized: "API Key"),
          text: keyDraftBinding(for: provider.id)
        )
        Button("保存") {
          let key = keyDrafts[provider.id] ?? ""
          guard !key.isEmpty else { return }
          if aiKeys.save(key, for: provider.id) {
            keyDrafts[provider.id] = ""
          }
        }
        .disabled((keyDrafts[provider.id] ?? "").isEmpty)
        if aiKeys.configuredAccounts.contains(provider.id) {
          Button("清除") {
            aiKeys.remove(for: provider.id)
          }
        }
      }
      customModelSpecsEditor(provider)
      HStack(spacing: 8) {
        Button("连接测试") {
          testConnection(provider.identity)
        }
        .disabled(!aiKeys.configuredAccounts.contains(provider.id)
          || aiSettings.config(for: provider.identity).models.isEmpty
          || testStates[provider.id] == .testing)
        switch testStates[provider.id] {
        case .testing:
          ProgressView().controlSize(.small)
        case .success(let message):
          Text(message).foregroundStyle(.green).font(.callout)
        case .failure(let message):
          Text(message).foregroundStyle(.red).font(.callout).lineLimit(2)
        case nil:
          EmptyView()
        }
      }
      Button(role: .destructive) {
        aiKeys.remove(for: provider.id)
        aiSettings.removeCustomProvider(provider.id)
      } label: {
        Label("删除该 Provider", systemImage: "trash")
      }
    } label: {
      Toggle(provider.name.isEmpty ? String(localized: "自定义") : provider.name, isOn: customBinding(provider.id, \.isEnabled, default: true))
    }
  }

  /// 自定义 Provider 的字段绑定（写入 aiSettings.updateCustomProvider；
  /// default 仅在渲染瞬间找不到条目时兜底。baseURL 即时清洗粘贴的空白/换行
  private func customBinding<T>(
    _ id: String, _ keyPath: WritableKeyPath<AICustomProvider, T>, default fallback: T
  ) -> Binding<T> {
    Binding(
      get: {
        aiSettings.settings.customProviders.first { $0.id == id }?[keyPath: keyPath] ?? fallback
      },
      set: { newValue in
        aiSettings.updateCustomProvider(id) { provider in
          if keyPath == \.baseURL, let text = newValue as? String {
            provider.baseURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
          } else {
            provider[keyPath: keyPath] = newValue
          }
        }
      }
    )
  }

  /// 自定义 Provider 的模型清单编辑（同内置 modelSpecsEditor 的交互，写入路径不同）
  @ViewBuilder
  private func customModelSpecsEditor(_ provider: AICustomProvider) -> some View {
    let specs = aiSettings.settings.customProviders.first { $0.id == provider.id }?.modelSpecs ?? []
    ForEach(specs, id: \.id) { spec in
      LabeledContent {
        HStack(spacing: 6) {
          TextField("", text: customSpecBinding(provider.id, spec.id, \.name, default: ""), prompt: Text("如 gpt-4o"))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 140)
          Text("窗口").font(.callout).foregroundStyle(.secondary).fixedSize()
          TextField("", value: customSpecBinding(provider.id, spec.id, \.contextTokens, default: AIModelContext.conservativeTokens), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
          Text("tokens").font(.callout).foregroundStyle(.secondary).fixedSize()
          Button {
            aiSettings.updateCustomProvider(provider.id) {
              $0.modelSpecs.removeAll { $0.id == spec.id }
            }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.plain)
          .controlSize(.small)
          .help("删除该模型")
        }
      } label: {
        Text("模型名")
      }
    }
    Button {
      aiSettings.updateCustomProvider(provider.id) {
        $0.modelSpecs.append(AIModelSpec(name: "", contextTokens: AIModelContext.conservativeTokens))
      }
    } label: {
      Label("添加模型", systemImage: "plus.circle")
        .font(.callout)
    }
    .buttonStyle(.plain)
  }

  private func customSpecBinding<T>(
    _ providerID: String, _ specID: UUID, _ keyPath: WritableKeyPath<AIModelSpec, T>, default fallback: T
  ) -> Binding<T> {
    Binding(
      get: {
        let specs = aiSettings.settings.customProviders.first { $0.id == providerID }?.modelSpecs ?? []
        return specs.first { $0.id == specID }?[keyPath: keyPath] ?? fallback
      },
      set: { newValue in
        aiSettings.updateCustomProvider(providerID) { provider in
          guard let index = provider.modelSpecs.firstIndex(where: { $0.id == specID }) else { return }
          let wasEmptyName = provider.modelSpecs[index].name.isEmpty
          provider.modelSpecs[index][keyPath: keyPath] = newValue
          if keyPath == \.name, wasEmptyName,
            provider.modelSpecs[index].contextTokens == AIModelContext.conservativeTokens
          {
            provider.modelSpecs[index].contextTokens = AIModelContext.suggestedTokens(forModel: newValue as? String ?? "")
          }
        }
      }
    )
  }

  // MARK: - 模型选择（对话 / 翻译共用：全部启用 Provider × 模型列表）

  @ViewBuilder
  private func modelPicker(title: String, selection: Binding<AIModelChoice?>, nilLabel: String) -> some View {
    let choices: [AIModelChoice] = aiSettings.allIdentities().flatMap { identity -> [AIModelChoice] in
      let config = aiSettings.config(for: identity)
      guard config.isEnabled else { return [] }
      return config.models.map { AIModelChoice(provider: identity.id, model: $0) }
    }
    if choices.isEmpty {
      Text("先在上方启用并配置至少一个 Provider")
        .foregroundStyle(.secondary)
    } else {
      Picker(title, selection: selection) {
        Text(nilLabel).tag(AIModelChoice?.none)
        ForEach(choices, id: \.self) { choice in
          Text("\(aiSettings.identity(for: choice.provider)?.title ?? choice.provider) · \(choice.model)")
            .tag(choice as AIModelChoice?)
        }
      }
    }
  }

  // MARK: - 连接测试

  private func testConnection(_ identity: AIProviderIdentity) {
    // 首次联网前隐私告知（FR-AI.4）；取消则不发任何请求
    guard AIPrivacyGate.ensureAcknowledged(store: aiSettings) else { return }
    testStates[identity.id] = .testing
    let config = aiSettings.config(for: identity)
    let service = AIService(keys: aiKeys)
    Task { @MainActor in
      do {
        let elapsed = try await service.testConnection(provider: identity, config: config, model: config.models.first ?? "")
        testStates[identity.id] = .success(String(format: String(localized: "连接正常（%.1fs）"), elapsed))
      } catch {
        // 「已配置」却报未配置 = 钥匙串旧条目 ACL 拒绝当前二进制（重新签名后出现）：
        // 重新保存一次即可触发条目重建自愈（KeychainAIKeyStorage.set）
        if case AIServiceError.missingAPIKey = error, aiKeys.configuredAccounts.contains(identity.id) {
          testStates[identity.id] = .failure(
            String(localized: "Key 无法读取：请重新粘贴并点「保存」一次以完成迁移"))
        } else {
          testStates[identity.id] = .failure(error.localizedDescription)
        }
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

  /// 模型逐行编辑（v1.3）：名称 + 上下文窗口 tokens（用户设定，不猜测）+ 删除/添加。
  /// LabeledContent 真标签锚定左缘：macOS Form 对无标签自定义行一律按固有宽度
  /// 顶到右缘（frame/Spacer/containerRelativeFrame 均无效，探针实锤），
  /// 走 Form 原生「标签+内容」两栏才对齐；行身份用 spec.id（下标复用不串行）
  @ViewBuilder
  private func modelSpecsEditor(_ kind: AIProviderKind) -> some View {
    let specs = aiSettings.config(for: kind).modelSpecs
    ForEach(specs, id: \.id) { spec in
      LabeledContent {
        HStack(spacing: 6) {
          // 名称框定宽：LabeledContent 首行会抢宽（实测首行明显更长），定宽各行一致
          TextField("", text: specBinding(kind, spec.id, \.name), prompt: Text("如 kimi-k3"))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 140)
            .focused($focusedModelField, equals: "\(kind.rawValue)#\(spec.id.uuidString)")
            .onSubmit { focusedModelField = nil }
          Text("窗口")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize()
          TextField("", value: specTokensBinding(kind, spec.id), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
            .focused($focusedModelField, equals: "\(kind.rawValue)#\(spec.id.uuidString)-tokens")
            .onSubmit { focusedModelField = nil }
            .help("该模型的上下文窗口（输入与输出共享），文档/历史预算据此分配")
          Text("tokens")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize()
          Button {
            aiSettings.updateConfig(kind) { config in
              config.modelSpecs.removeAll { $0.id == spec.id }
            }
            if focusedModelField?.hasPrefix("\(kind.rawValue)#\(spec.id.uuidString)") == true {
              focusedModelField = nil
            }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.plain)
          .controlSize(.small)
          .help("删除该模型")
        }
      } label: {
        Text("模型名")
      }
    }
    Button {
      aiSettings.updateConfig(kind) {
        $0.modelSpecs.append(AIModelSpec(name: "", contextTokens: AIModelContext.conservativeTokens))
      }
    } label: {
      Label("添加模型", systemImage: "plus.circle")
        .font(.callout)
    }
    .buttonStyle(.plain)
  }

  private func specBinding(_ kind: AIProviderKind, _ specID: UUID, _ keyPath: WritableKeyPath<AIModelSpec, String>) -> Binding<String> {
    Binding(
      get: {
        let specs = aiSettings.config(for: kind).modelSpecs
        guard let index = specs.firstIndex(where: { $0.id == specID }) else { return "" }
        return specs[index][keyPath: keyPath]
      },
      set: { newValue in
        aiSettings.updateConfig(kind) { config in
          guard let index = config.modelSpecs.firstIndex(where: { $0.id == specID }) else { return }
          let wasEmptyName = config.modelSpecs[index].name.isEmpty
          config.modelSpecs[index][keyPath: keyPath] = newValue
          // 仅首次填写名称时按模型名预填建议窗口：「等于保守值」区分不了
          // 用户刻意手填的 32000，改名不得悄悄改写用户设过的窗口
          if keyPath == \.name, wasEmptyName, config.modelSpecs[index].contextTokens == AIModelContext.conservativeTokens {
            config.modelSpecs[index].contextTokens = AIModelContext.suggestedTokens(forModel: newValue)
          }
        }
      }
    )
  }

  private func specTokensBinding(_ kind: AIProviderKind, _ specID: UUID) -> Binding<Int> {
    Binding(
      get: {
        let specs = aiSettings.config(for: kind).modelSpecs
        guard let index = specs.firstIndex(where: { $0.id == specID }) else {
          return AIModelContext.conservativeTokens
        }
        return specs[index].contextTokens
      },
      set: { newValue in
        aiSettings.updateConfig(kind) { config in
          guard let index = config.modelSpecs.firstIndex(where: { $0.id == specID }) else { return }
          config.modelSpecs[index].contextTokens = max(newValue, 1_000)
        }
      }
    )
  }

  private func enabledBinding(_ kind: AIProviderKind) -> Binding<Bool> {
    Binding(
      get: { aiSettings.config(for: kind).isEnabled },
      set: { newValue in aiSettings.updateConfig(kind) { $0.isEnabled = newValue } }
    )
  }

  private func keyDraftBinding(for account: String) -> Binding<String> {
    Binding(
      get: { keyDrafts[account] ?? "" },
      set: { keyDrafts[account] = $0 }
    )
  }
}

#Preview {
  AISettingsView()
    .environmentObject(AISettingsStore())
    .environmentObject(AIKeyStore())
    .frame(width: 500, height: 520)
}
