import SwiftUI

/// 设置页 AI 分区（FR-AI.4）：Provider 管理（Keychain 密钥 + 连接测试）、
/// 划词翻译偏好（引擎 / 目标语言 / 自动触发）、AI 助手偏好（对话模型 / 三层上下文开关）。
struct AISettingsView: View {
  @EnvironmentObject private var aiSettings: AISettingsStore
  @EnvironmentObject private var aiKeys: AIKeyStore

  @State private var keyDrafts: [String: String] = [:]
  @State private var testStates: [String: ConnectionTestState] = [:]
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
        .help("请求的 max_tokens；超过模型窗口时自动夹取到窗口一半")
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
          text: keyDraftBinding(for: kind)
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
