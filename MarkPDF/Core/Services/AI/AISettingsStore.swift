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
    case .auto: "自动（中英互译）"
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
    case .system: "系统翻译"
    case .ai: "AI 大模型"
    }
  }
}

/// AI 偏好设置（FR-AI.4）：整体 JSON 存 UserDefaults 单键；
/// 解码全部 decodeIfPresent + 默认值，向后兼容新增字段。
struct AISettings: Codable, Equatable {
  /// Provider 配置表，key = AIProviderKind.rawValue；未配置的 Provider 用预设默认
  var providers: [String: AIProviderConfig] = [:]
  /// AI 助手对话使用的 Provider（nil = 自动取第一个已启用的）
  var chatProvider: String?
  var translationEngine: AITranslationEngine = .system
  /// 翻译使用的 Provider（nil = 跟随 chatProvider）
  var translationProvider: String?
  var targetLanguage: AITargetLanguage = .auto
  var autoTranslateOnSelection = true
  /// 三层上下文开关（FR-AI.2）：工作区默认关（隐私保守）
  var contextIncludeSelection = true
  var contextIncludeDocument = true
  var contextIncludeWorkspace = false

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    providers = try container.decodeIfPresent([String: AIProviderConfig].self, forKey: .providers) ?? [:]
    chatProvider = try container.decodeIfPresent(String.self, forKey: .chatProvider)
    translationEngine = try container.decodeIfPresent(AITranslationEngine.self, forKey: .translationEngine) ?? .system
    translationProvider = try container.decodeIfPresent(String.self, forKey: .translationProvider)
    targetLanguage = try container.decodeIfPresent(AITargetLanguage.self, forKey: .targetLanguage) ?? .auto
    autoTranslateOnSelection = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateOnSelection) ?? true
    contextIncludeSelection = try container.decodeIfPresent(Bool.self, forKey: .contextIncludeSelection) ?? true
    contextIncludeDocument = try container.decodeIfPresent(Bool.self, forKey: .contextIncludeDocument) ?? true
    contextIncludeWorkspace = try container.decodeIfPresent(Bool.self, forKey: .contextIncludeWorkspace) ?? false
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

  /// AI 助手对话 Provider：显式选择且已启用则用之，否则第一个已启用的；全未启用为 nil
  var chatProviderKind: AIProviderKind? {
    resolveProvider(settings.chatProvider)
  }

  /// 翻译 Provider（引擎为 AI 时）：未单独配置则跟随对话 Provider
  var translationProviderKind: AIProviderKind? {
    resolveProvider(settings.translationProvider ?? settings.chatProvider)
  }

  private func resolveProvider(_ raw: String?) -> AIProviderKind? {
    if let raw, let kind = AIProviderKind(rawValue: raw), config(for: kind).isEnabled {
      return kind
    }
    return AIProviderKind.allCases.first { config(for: $0).isEnabled }
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Key.ai)
  }
}
