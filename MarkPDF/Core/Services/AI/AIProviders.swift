import Foundation

/// AI 调用错误（FR-AI.4）：文案面向用户可读（NFR-5）；日志只记状态码与 Provider，不落正文
enum AIServiceError: LocalizedError, Equatable {
  case missingAPIKey
  case invalidConfiguration(String)
  case httpStatus(Int, String)
  case provider(String)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      String(localized: "未配置 API Key，请在设置中填写")
    case .invalidConfiguration(let detail):
      String(localized: "配置无效：\(detail)")
    case .httpStatus(let status, let snippet):
      String(localized: "服务返回 HTTP \(status)\(snippet.isEmpty ? "" : "：\(snippet)")")
    case .provider(let message):
      message
    case .invalidResponse:
      String(localized: "响应格式无法识别")
    }
  }

  /// 日志安全描述（规范 §6「日志不落正文」：错误体摘录可能含敏感回显，只用于 UI 展示）。
  /// 仅进日志不进 UI，保持中文便于检索，不本地化
  var logSafeDescription: String {
    switch self {
    case .missingAPIKey: "未配置 API Key"
    case .invalidConfiguration: "配置无效"
    case .httpStatus(let status, _): "HTTP \(status)"
    case .provider: "Provider 错误"
    case .invalidResponse: "响应格式无法识别"
    }
  }
}

/// 请求构造（FR-AI.4）：纯函数不触网，可单测。
enum AIRequestBuilder {
  static func chatRequest(
    family: AIProtocolFamily,
    config: AIProviderConfig,
    apiKey: String,
    model: String,
    messages: [AIChatMessage],
    stream: Bool,
    maxTokens: Int = 4096
  ) throws -> URLRequest {
    switch family {
    case .openAICompatible:
      return try openAIRequest(config: config, apiKey: apiKey, model: model, messages: messages, stream: stream, maxTokens: maxTokens)
    case .anthropic:
      return try anthropicRequest(config: config, apiKey: apiKey, model: model, messages: messages, stream: stream, maxTokens: maxTokens)
    }
  }

  // MARK: - OpenAI 兼容协议（POST {baseURL}/chat/completions）

  private struct OpenAIChatBody: Encodable {
    let model: String
    let messages: [AIChatMessage]
    let stream: Bool
    // 回复上限与 Anthropic 口径统一（当前预设模型族均接受 max_tokens；
    // OpenAI 新模型族改名 max_completion_tokens 属已知偏差，见进度文档）
    let max_tokens: Int
  }

  private static func openAIRequest(
    config: AIProviderConfig,
    apiKey: String,
    model: String,
    messages: [AIChatMessage],
    stream: Bool,
    maxTokens: Int
  ) throws -> URLRequest {
    var request = try baseRequest(url: config.endpoint + "/chat/completions")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(OpenAIChatBody(model: model, messages: messages, stream: stream, max_tokens: maxTokens))
    return request
  }

  // MARK: - Anthropic Messages API（POST {baseURL}/v1/messages）

  private struct AnthropicChatBody: Encodable {
    let model: String
    let max_tokens: Int
    let messages: [AIChatMessage]
    let system: String?
    let stream: Bool
  }

  private static func anthropicRequest(
    config: AIProviderConfig,
    apiKey: String,
    model: String,
    messages: [AIChatMessage],
    stream: Bool,
    maxTokens: Int
  ) throws -> URLRequest {
    var request = try baseRequest(url: config.endpoint + "/v1/messages")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    // system 为顶层字段而非消息；多段 system 合并
    let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
    let turns = messages.filter { $0.role != .system }
    request.httpBody = try JSONEncoder().encode(AnthropicChatBody(
      model: model,
      max_tokens: maxTokens,
      messages: turns,
      system: system.isEmpty ? nil : system,
      stream: stream
    ))
    return request
  }

  private static func baseRequest(url: String) throws -> URLRequest {
    guard let parsed = URL(string: url) else {
      throw AIServiceError.invalidConfiguration(String(localized: "Base URL 无法解析"))
    }
    // Bearer/x-api-key 会随请求发出：必须 https；仅本地回环（mock 调试）放行 http，防明文泄钥
    let loopback = ["127.0.0.1", "localhost", "::1"].contains(parsed.host ?? "")
    guard parsed.host != nil, parsed.scheme == "https" || (parsed.scheme == "http" && loopback) else {
      throw AIServiceError.invalidConfiguration(String(localized: "Base URL 必须是 https 地址（本地调试可用 http://127.0.0.1）"))
    }
    var request = URLRequest(url: parsed, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }
}

private extension AIProviderConfig {
  /// 去掉全部尾部 / 的 baseURL，供拼接端点路径（`https://x.com/v1//` 不再拼出双斜杠）
  var endpoint: String {
    baseURL.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
  }
}

// MARK: - 流式增量解码

enum AIChunkDecoder {
  enum AnthropicOutcome: Equatable {
    case delta(String)
    case finished
    case ignored
  }

  struct OpenAIErrorPayload: Decodable {
    struct ErrorBody: Decodable { let message: String }
    let error: ErrorBody
  }

  private struct OpenAIChunk: Decodable {
    struct Choice: Decodable {
      struct Delta: Decodable { let content: String? }
      let delta: Delta
    }
    let choices: [Choice]
  }

  struct AnthropicErrorPayload: Decodable {
    struct ErrorBody: Decodable { let message: String }
    let error: ErrorBody
  }

  private struct AnthropicContentBlockDelta: Decodable {
    struct Delta: Decodable { let text: String? }
    let delta: Delta
  }

  /// OpenAI 兼容流：单个 data 载荷 → 文本增量；[DONE] 哨兵与无内容增量返回 nil；error 载荷抛错
  static func openAIDelta(from payload: String) throws -> String? {
    if payload == "[DONE]" { return nil }
    guard let data = payload.data(using: .utf8) else { return nil }
    if let error = try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data) {
      throw AIServiceError.provider(error.error.message)
    }
    let chunk = try JSONDecoder().decode(OpenAIChunk.self, from: data)
    return chunk.choices.first?.delta.content
  }

  /// Anthropic 流：event + data → 增量/结束/忽略；error 事件抛错
  static func anthropicDelta(event: String?, payload: String) throws -> AnthropicOutcome {
    guard let data = payload.data(using: .utf8) else { return .ignored }
    if event == "error" {
      let parsed = try? JSONDecoder().decode(AnthropicErrorPayload.self, from: data)
      throw AIServiceError.provider(parsed?.error.message ?? String(localized: "Anthropic 返回错误"))
    }
    switch event {
    case "content_block_delta":
      let parsed = try JSONDecoder().decode(AnthropicContentBlockDelta.self, from: data)
      return .delta(parsed.delta.text ?? "")
    case "message_stop":
      return .finished
    default:
      // message_start / content_block_start/stop / message_delta / ping 等
      return .ignored
    }
  }
}

// MARK: - 非流式全量响应解码

enum AIResponseDecoder {
  private struct OpenAICompletion: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable { let content: String? }
      let message: Message
    }
    let choices: [Choice]
  }

  private struct AnthropicCompletion: Decodable {
    struct Block: Decodable {
      let type: String
      let text: String?
    }
    let content: [Block]
  }

  static func openAIMessage(from data: Data) throws -> String {
    if let error = try? JSONDecoder().decode(AIChunkDecoder.OpenAIErrorPayload.self, from: data) {
      throw AIServiceError.provider(error.error.message)
    }
    let response = try JSONDecoder().decode(OpenAICompletion.self, from: data)
    guard let text = response.choices.first?.message.content, !text.isEmpty else {
      throw AIServiceError.invalidResponse
    }
    return text
  }

  static func anthropicMessage(from data: Data) throws -> String {
    if let error = try? JSONDecoder().decode(AIChunkDecoder.AnthropicErrorPayload.self, from: data) {
      throw AIServiceError.provider(error.error.message)
    }
    let response = try JSONDecoder().decode(AnthropicCompletion.self, from: data)
    let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
    guard !text.isEmpty else {
      throw AIServiceError.invalidResponse
    }
    return text
  }
}
