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

/// 模型规格（FR-AI.2 v1.3）：上下文窗口由用户配置（不猜测；新增时按模型名预填建议值）
struct AIModelSpec: Codable, Equatable, Hashable {
  /// 稳定身份（行删除后列表下标复用也不会串行：编辑器绑定与焦点键用）；
  /// 旧配置无此字段，解码时补发
  var id = UUID()
  var name: String
  /// 上下文窗口（tokens，输入与输出共享）；用户可改，以用户值为准
  var contextTokens: Int

  init(id: UUID = UUID(), name: String, contextTokens: Int) {
    self.id = id
    self.name = name
    self.contextTokens = contextTokens
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, contextTokens
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decode(String.self, forKey: .name)
    contextTokens = try container.decode(Int.self, forKey: .contextTokens)
  }
}

/// 单个 Provider 的用户配置；API Key 不入此结构（存 Keychain，见 AIKeyStore）。
/// 一个 Provider 可配多个模型（翻译用小模型、助手用大模型各取所需）
struct AIProviderConfig: Codable, Equatable {
  var isEnabled: Bool
  var baseURL: String
  var modelSpecs: [AIModelSpec]

  /// 模型名列表（选择器/解析用）
  var models: [String] { modelSpecs.map(\.name) }

  func spec(for model: String) -> AIModelSpec? {
    modelSpecs.first { $0.name == model }
  }

  init(isEnabled: Bool, baseURL: String, modelSpecs: [AIModelSpec]) {
    self.isEnabled = isEnabled
    self.baseURL = baseURL
    self.modelSpecs = modelSpecs
  }

  /// 名称列表便捷构造（窗口按模型名预填建议值）
  init(isEnabled: Bool, baseURL: String, models: [String]) {
    self.init(
      isEnabled: isEnabled,
      baseURL: baseURL,
      modelSpecs: models.map { AIModelSpec(name: $0, contextTokens: AIModelContext.suggestedTokens(forModel: $0)) }
    )
  }

  /// 单模型便捷构造（预设默认与测试用）
  init(isEnabled: Bool, baseURL: String, model: String) {
    self.init(isEnabled: isEnabled, baseURL: baseURL, models: [model])
  }

  private enum CodingKeys: String, CodingKey {
    case isEnabled, baseURL, modelSpecs, models, model
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    if let specs = try container.decodeIfPresent([AIModelSpec].self, forKey: .modelSpecs) {
      modelSpecs = specs
    } else if let names = try container.decodeIfPresent([String].self, forKey: .models) {
      // 旧版模型名数组迁移：窗口按模型名预填建议值
      modelSpecs = names.map { AIModelSpec(name: $0, contextTokens: AIModelContext.suggestedTokens(forModel: $0)) }
    } else if let legacy = try container.decodeIfPresent(String.self, forKey: .model), !legacy.isEmpty {
      // 更旧的单模型字段迁移
      modelSpecs = [AIModelSpec(name: legacy, contextTokens: AIModelContext.suggestedTokens(forModel: legacy))]
    } else {
      modelSpecs = []
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(baseURL, forKey: .baseURL)
    try container.encode(modelSpecs, forKey: .modelSpecs)
  }
}

/// 功能级模型选择（翻译/AI 助手各自独立）：Provider + 该 Provider 模型列表中的一个。
/// model 为空串 = 用该 Provider 的第一个模型（旧版仅 Provider 粒度选择的迁移形态）
struct AIModelChoice: Codable, Equatable, Hashable {
  var provider: String
  var model: String
}

/// 模型请求的一次工具调用（FR-AI.2 v1.3 agent 循环）；arguments 为 JSON 字符串
struct AIToolCall: Codable, Equatable {
  let id: String
  let name: String
  let arguments: String
}

/// 工具定义（送入两族 tools 参数）；parametersJSON 为 JSON Schema 原文
struct AITool: Equatable {
  let name: String
  let description: String
  let parametersJSON: String
}

/// 对话消息（FR-AI.2 多轮会话的基本单元）。
/// v1.3：支持工具轮——assistant 可携带 toolCalls；tool 角色为工具结果（toolCallID 配对）
struct AIChatMessage: Codable, Equatable {
  enum Role: String, Codable {
    case system
    case user
    case assistant
    case tool
  }

  var role: Role
  var content: String
  /// assistant 请求的工具调用（agent 循环轮内使用）
  var toolCalls: [AIToolCall]?
  /// tool 角色：所应答的调用 id
  var toolCallID: String?

  init(role: Role, content: String, toolCalls: [AIToolCall]? = nil, toolCallID: String? = nil) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }

  static func system(_ text: String) -> AIChatMessage { AIChatMessage(role: .system, content: text) }
  static func user(_ text: String) -> AIChatMessage { AIChatMessage(role: .user, content: text) }
  static func assistant(_ text: String) -> AIChatMessage { AIChatMessage(role: .assistant, content: text) }
  static func toolResult(id: String, content: String) -> AIChatMessage {
    AIChatMessage(role: .tool, content: content, toolCallID: id)
  }
}
