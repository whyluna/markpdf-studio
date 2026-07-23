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
    case .kimi: "Kimi（月之暗面）"
    case .qwen: "通义千问 Qwen"
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

/// 单个 Provider 的用户配置；API Key 不入此结构（存 Keychain，见 AIKeyStore）
struct AIProviderConfig: Codable, Equatable {
  var isEnabled: Bool
  var baseURL: String
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
