import Foundation

/// AI 协议族（FR-AI.4）：OpenAI 兼容协议覆盖 GPT/DeepSeek/Kimi/Qwen/Gemini 兼容端点；
/// Claude 走 Anthropic 原生 Messages API。
enum AIProtocolFamily: String, Codable {
  case openAICompatible
  case anthropic
}

/// 内置 Provider 预设（baseURL/模型均可在设置页修改，此处仅默认）
enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
  case openai
  case deepseek
  case kimi
  case qwen
  case gemini
  case anthropic

  var id: String { rawValue }

  var title: String {
    switch self {
    case .openai: "OpenAI"
    case .deepseek: "DeepSeek"
    case .kimi: String(localized: "Kimi（月之暗面）")
    case .qwen: String(localized: "通义千问 Qwen")
    case .gemini: "Google Gemini"
    case .anthropic: "Claude（Anthropic）"
    }
  }

  var family: AIProtocolFamily {
    self == .anthropic ? .anthropic : .openAICompatible
  }

  var defaultBaseURL: String {
    switch self {
    case .openai: "https://api.openai.com/v1"
    case .deepseek: "https://api.deepseek.com/v1"
    case .kimi: "https://api.moonshot.cn/v1"
    case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
    case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
    case .anthropic: "https://api.anthropic.com"
    }
  }

  var defaultModel: String {
    switch self {
    case .openai: "gpt-4o-mini"
    case .deepseek: "deepseek-chat"
    case .kimi: "moonshot-v1-8k"
    case .qwen: "qwen-plus"
    case .gemini: "gemini-2.0-flash"
    case .anthropic: "claude-3-5-sonnet-latest"
    }
  }

  var defaultConfig: AIProviderConfig {
    AIProviderConfig(isEnabled: false, baseURL: defaultBaseURL, model: defaultModel)
  }
}

/// 单个 Provider 的用户配置；API Key 不入此结构（存 Keychain，见 AIKeyStore）。
/// 一个 Provider 可配多个模型（翻译用小模型、助手用大模型各取所需）
struct AIProviderConfig: Codable, Equatable {
  var isEnabled: Bool
  var baseURL: String
  var models: [String]

  init(isEnabled: Bool, baseURL: String, models: [String]) {
    self.isEnabled = isEnabled
    self.baseURL = baseURL
    self.models = models
  }

  /// 单模型便捷构造（预设默认与测试用）
  init(isEnabled: Bool, baseURL: String, model: String) {
    self.init(isEnabled: isEnabled, baseURL: baseURL, models: [model])
  }

  private enum CodingKeys: String, CodingKey {
    case isEnabled, baseURL, models, model
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    if let list = try container.decodeIfPresent([String].self, forKey: .models) {
      models = list
    } else if let legacy = try container.decodeIfPresent(String.self, forKey: .model) {
      // 旧版单模型字段迁移
      models = legacy.isEmpty ? [] : [legacy]
    } else {
      models = []
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(baseURL, forKey: .baseURL)
    try container.encode(models, forKey: .models)
  }
}

/// 功能级模型选择（翻译/AI 助手各自独立）：Provider + 该 Provider 模型列表中的一个。
/// model 为空串 = 用该 Provider 的第一个模型（旧版仅 Provider 粒度选择的迁移形态）
struct AIModelChoice: Codable, Equatable, Hashable {
  var provider: String
  var model: String
}

/// 对话消息（FR-AI.2 多轮会话的基本单元）
struct AIChatMessage: Codable, Equatable {
  enum Role: String, Codable {
    case system
    case user
    case assistant
  }

  var role: Role
  var content: String

  static func system(_ text: String) -> AIChatMessage { AIChatMessage(role: .system, content: text) }
  static func user(_ text: String) -> AIChatMessage { AIChatMessage(role: .user, content: text) }
  static func assistant(_ text: String) -> AIChatMessage { AIChatMessage(role: .assistant, content: text) }
}
