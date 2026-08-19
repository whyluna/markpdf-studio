import Foundation

/// 划词翻译目标语言（FR-AI.1）：默认中英互译自动判断，支持常见语言译中文
enum AITargetLanguage: String, Codable, CaseIterable, Identifiable {
  case auto
  case zh
  case en
  case ja
  case ko
  case fr
  case de
  case es
  case ru

  var id: String { rawValue }

  var title: String {
    switch self {
    case .auto: String(localized: "自动（中英互译）")
    // 语言名用自体（autonym），任何界面语言下都可辨认，不本地化
    case .zh: "中文"
    case .en: "English"
    case .ja: "日本語"
    case .ko: "한국어"
    case .fr: "Français"
    case .de: "Deutsch"
    case .es: "Español"
    case .ru: "Русский"
    }
  }
}

/// 划词翻译引擎（FR-AI.1）：系统翻译（TranslationSession）/ AI 大模型
enum AITranslationEngine: String, Codable, CaseIterable, Identifiable {
  case system
  case ai

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: String(localized: "系统翻译")
    case .ai: String(localized: "AI 大模型")
    }
  }
}

/// AI 偏好设置（FR-AI.4）：整体 JSON 存 UserDefaults 单键；
/// 解码全部 decodeIfPresent + 默认值，向后兼容新增字段。
struct AISettings: Codable, Equatable {
  /// Provider 配置表，key = AIProviderKind.rawValue；未配置的 Provider 用预设默认
  var providers: [String: AIProviderConfig] = [:]
  /// AI 助手对话模型（nil = 自动：第一个已启用 Provider 的第一个模型）
  var chatModel: AIModelChoice?
  var translationEngine: AITranslationEngine = .system
  /// 翻译模型（引擎为 AI 时；nil = 跟随对话模型）
  var translationModel: AIModelChoice?
  var targetLanguage: AITargetLanguage = .auto
  var autoTranslateOnSelection = true
  /// 三层上下文开关（FR-AI.2）：工作区默认关（隐私保守）
  var contextIncludeSelection = true
  var contextIncludeDocument = true
  var contextIncludeWorkspace = false
  /// AI 助手回复长度上限（max_tokens，用户设定；FR-AI.2 v1.3）
  var chatMaxReplyTokens = 8192
  /// 写作模式回复上限（v2.1 用户决策：与问答分开单独设）——工具调用里的文件
  /// 内容也占 max_tokens，写作需要独立且更大的额度
  var writingMaxReplyTokens = 16_384
  /// 自定义 Provider 清单（v2.1）
  var customProviders: [AICustomProvider] = []

  init() {}

  private enum CodingKeys: String, CodingKey {
    case providers, chatModel, translationEngine, translationModel, targetLanguage
    case autoTranslateOnSelection, contextIncludeSelection, contextIncludeDocument, contextIncludeWorkspace
    case chatMaxReplyTokens, writingMaxReplyTokens, customProviders
    // 旧版仅 Provider 粒度的选择字段（迁移用）
    case chatProvider, translationProvider
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    providers = try container.decodeIfPresent([String: AIProviderConfig].self, forKey: .providers) ?? [:]
    // 旧版 chatProvider/translationProvider（字符串）迁移为模型级选择（model 空串 = 该 Provider 首模型）
    if let choice = try container.decodeIfPresent(AIModelChoice.self, forKey: .chatModel) {
      chatModel = choice
    } else if let legacy = try container.decodeIfPresent(String.self, forKey: .chatProvider) {
      chatModel = AIModelChoice(provider: legacy, model: "")
    }
    if let choice = try container.decodeIfPresent(AIModelChoice.self, forKey: .translationModel) {
      translationModel = choice
    } else if let legacy = try container.decodeIfPresent(String.self, forKey: .translationProvider) {
      translationModel = AIModelChoice(provider: legacy, model: "")
    }
    translationEngine = try container.decodeIfPresent(AITranslationEngine.self, forKey: .translationEngine) ?? .system
    targetLanguage = try container.decodeIfPresent(AITargetLanguage.self, forKey: .targetLanguage) ?? .auto
    autoTranslateOnSelection = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateOnSelection) ?? true
    contextIncludeSelection = try container.decodeIfPresent(Bool.self, forKey: .contextIncludeSelection) ?? true
    contextIncludeDocument = try container.decodeIfPresent(Bool.self, forKey: .contextIncludeDocument) ?? true
    contextIncludeWorkspace = try container.decodeIfPresent(Bool.self, forKey: .contextIncludeWorkspace) ?? false
    chatMaxReplyTokens = try container.decodeIfPresent(Int.self, forKey: .chatMaxReplyTokens) ?? 8192
    writingMaxReplyTokens = try container.decodeIfPresent(Int.self, forKey: .writingMaxReplyTokens) ?? 16_384
    customProviders = try container.decodeIfPresent([AICustomProvider].self, forKey: .customProviders) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(providers, forKey: .providers)
    try container.encodeIfPresent(chatModel, forKey: .chatModel)
    try container.encode(translationEngine, forKey: .translationEngine)
    try container.encodeIfPresent(translationModel, forKey: .translationModel)
    try container.encode(targetLanguage, forKey: .targetLanguage)
    try container.encode(autoTranslateOnSelection, forKey: .autoTranslateOnSelection)
    try container.encode(contextIncludeSelection, forKey: .contextIncludeSelection)
    try container.encode(contextIncludeDocument, forKey: .contextIncludeDocument)
    try container.encode(contextIncludeWorkspace, forKey: .contextIncludeWorkspace)
    try container.encode(chatMaxReplyTokens, forKey: .chatMaxReplyTokens)
    try container.encode(writingMaxReplyTokens, forKey: .writingMaxReplyTokens)
    try container.encode(customProviders, forKey: .customProviders)
  }
}

/// AI 偏好门面（FR-AI.4）：UserDefaults 持久化，改动即时生效
@MainActor
final class AISettingsStore: ObservableObject {
  @Published private(set) var settings: AISettings {
    didSet { persist() }
  }

  /// 首次使用 AI 功能的隐私告知（FR-AI.4；AIPrivacyGate 消费）
  @Published var privacyNoticeAcknowledged: Bool {
    didSet { defaults.set(privacyNoticeAcknowledged, forKey: Key.privacyAcknowledged) }
  }

  private let defaults: UserDefaults

  private enum Key {
    static let ai = "settings.ai.v1"
    static let privacyAcknowledged = "settings.ai.privacyAcknowledged"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Key.ai),
       let decoded = try? JSONDecoder().decode(AISettings.self, from: data)
    {
      settings = decoded
    } else {
      settings = AISettings()
    }
    privacyNoticeAcknowledged = defaults.bool(forKey: Key.privacyAcknowledged)
  }

  func update(_ mutate: (inout AISettings) -> Void) {
    var copy = settings
    mutate(&copy)
    settings = copy
  }

  /// 读取某 Provider 配置（未存过则给预设默认）
  func config(for kind: AIProviderKind) -> AIProviderConfig {
    settings.providers[kind.rawValue] ?? kind.defaultConfig
  }

  // MARK: - 统一身份（内置 + 自定义，v2.1）

  /// 全部 Provider 身份：内置在前，自定义在后（模型选择器/回落遍历用）
  func allIdentities() -> [AIProviderIdentity] {
    AIProviderKind.allCases.map(\.identity) + settings.customProviders.map(\.identity)
  }

  func identity(for id: String) -> AIProviderIdentity? {
    allIdentities().first { $0.id == id }
  }

  /// 按统一身份取配置（自定义 = 用户填写的 baseURL/模型清单合成）
  func config(for identity: AIProviderIdentity) -> AIProviderConfig {
    if let kind = AIProviderKind(rawValue: identity.id) {
      return config(for: kind)
    }
    return settings.customProviders.first { $0.id == identity.id }?.config
      ?? AIProviderConfig(isEnabled: false, baseURL: "", models: [])
  }

  /// 新增自定义 Provider（返回新增项供 UI 展开编辑）
  @discardableResult
  func addCustomProvider() -> AICustomProvider {
    var provider = AICustomProvider()
    provider.name = String(localized: "自定义")
    update { $0.customProviders.append(provider) }
    return provider
  }

  func updateCustomProvider(_ id: String, _ mutate: (inout AICustomProvider) -> Void) {
    update { settings in
      guard let index = settings.customProviders.firstIndex(where: { $0.id == id }) else { return }
      mutate(&settings.customProviders[index])
    }
  }

  /// 删除自定义 Provider（选择引用一并清除，回落链自动接管；Key 由 UI 层清）
  func removeCustomProvider(_ id: String) {
    update { settings in
      settings.customProviders.removeAll { $0.id == id }
      if settings.chatModel?.provider == id { settings.chatModel = nil }
      if settings.translationModel?.provider == id { settings.translationModel = nil }
    }
  }

  func updateConfig(_ kind: AIProviderKind, _ mutate: (inout AIProviderConfig) -> Void) {
    update { settings in
      var config = settings.providers[kind.rawValue] ?? kind.defaultConfig
      mutate(&config)
      settings.providers[kind.rawValue] = config
    }
  }

  /// 解析后的可用模型（统一身份 + 配置 + 模型名 + 用户设定窗口），供请求链直接使用
  struct ResolvedModel: Equatable {
    let provider: AIProviderIdentity
    let config: AIProviderConfig
    let model: String
    /// 上下文窗口（tokens，用户设定；未配置回退保守值）
    let contextTokens: Int
  }

  /// AI 助手对话模型：显式选择有效则用之，否则第一个已启用 Provider 的第一个模型；全不可用为 nil
  var chatSelection: ResolvedModel? {
    resolve(settings.chatModel)
  }

  /// 翻译模型（引擎为 AI 时）：未单独选择则跟随对话模型
  var translationSelection: ResolvedModel? {
    resolve(settings.translationModel ?? settings.chatModel)
  }

  private func resolve(_ choice: AIModelChoice?) -> ResolvedModel? {
    func resolved(_ identity: AIProviderIdentity, _ config: AIProviderConfig, _ model: String) -> ResolvedModel {
      ResolvedModel(
        provider: identity,
        config: config,
        model: model,
        contextTokens: config.spec(for: model)?.contextTokens ?? AIModelContext.conservativeTokens
      )
    }
    // 显式选择：内置或自定义 id 均可命中
    if let choice, let identity = identity(for: choice.provider) {
      let config = config(for: identity)
      if config.isEnabled, !config.models.isEmpty {
        // 所选模型仍在列表内用之；被删掉则回落该 Provider 首模型（空串迁移形态同此）
        let model = config.models.contains(choice.model) ? choice.model : config.models[0]
        return resolved(identity, config, model)
      }
    }
    // 回落：第一个已启用且有模型的 Provider（内置在前、自定义在后）
    for identity in allIdentities() {
      let config = config(for: identity)
      if config.isEnabled, let first = config.models.first {
        return resolved(identity, config, first)
      }
    }
    return nil
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Key.ai)
  }
}
