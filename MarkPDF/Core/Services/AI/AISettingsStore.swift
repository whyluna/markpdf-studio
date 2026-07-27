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

  init() {}

  private enum CodingKeys: String, CodingKey {
    case providers, chatModel, translationEngine, translationModel, targetLanguage
    case autoTranslateOnSelection, contextIncludeSelection, contextIncludeDocument, contextIncludeWorkspace
    case chatMaxReplyTokens
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

  func updateConfig(_ kind: AIProviderKind, _ mutate: (inout AIProviderConfig) -> Void) {
    update { settings in
      var config = settings.providers[kind.rawValue] ?? kind.defaultConfig
      mutate(&config)
      settings.providers[kind.rawValue] = config
    }
  }

  /// 解析后的可用模型（kind + 配置 + 模型名 + 用户设定窗口），供请求链直接使用
  struct ResolvedModel: Equatable {
    let kind: AIProviderKind
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
    func resolved(_ kind: AIProviderKind, _ config: AIProviderConfig, _ model: String) -> ResolvedModel {
      ResolvedModel(
        kind: kind,
        config: config,
        model: model,
        contextTokens: config.spec(for: model)?.contextTokens ?? AIModelContext.conservativeTokens
      )
    }
    if let choice, let kind = AIProviderKind(rawValue: choice.provider) {
      let config = config(for: kind)
      if config.isEnabled, !config.models.isEmpty {
        // 所选模型仍在列表内用之；被删掉则回落该 Provider 首模型（空串迁移形态同此）
        let model = config.models.contains(choice.model) ? choice.model : config.models[0]
        return resolved(kind, config, model)
      }
    }
    // 回落：第一个已启用且有模型的 Provider
    for kind in AIProviderKind.allCases {
      let config = config(for: kind)
      if config.isEnabled, let first = config.models.first {
        return resolved(kind, config, first)
      }
    }
    return nil
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Key.ai)
  }
}
