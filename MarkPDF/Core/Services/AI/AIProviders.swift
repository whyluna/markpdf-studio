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
      "未配置 API Key，请在设置中填写"
    case .invalidConfiguration(let detail):
      "配置无效：\(detail)"
    case .httpStatus(let status, let snippet):
      "服务返回 HTTP \(status)\(snippet.isEmpty ? "" : "：\(snippet)")"
    case .provider(let message):
      message
    case .invalidResponse:
      "响应格式无法识别"
    }
  }
}

/// 请求构造（FR-AI.4）：纯函数不触网，可单测。
enum AIRequestBuilder {
  static func chatRequest(
    family: AIProtocolFamily,
    config: AIProviderConfig,
    apiKey: String,
    messages: [AIChatMessage],
    stream: Bool,
    maxTokens: Int = 4096
  ) throws -> URLRequest {
    switch family {
    case .openAICompatible:
      return try openAIRequest(config: config, apiKey: apiKey, messages: messages, stream: stream)
    case .anthropic:
      return try anthropicRequest(config: config, apiKey: apiKey, messages: messages, stream: stream, maxTokens: maxTokens)
    }
  }

  // MARK: - OpenAI 兼容协议（POST {baseURL}/chat/completions）

  private struct OpenAIChatBody: Encodable {
    let model: String
    let messages: [AIChatMessage]
    let stream: Bool
  }

  private static func openAIRequest(
    config: AIProviderConfig,
    apiKey: String,
    messages: [AIChatMessage],
    stream: Bool
  ) throws -> URLRequest {
    var request = try baseRequest(url: config.endpoint + "/chat/completions")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(OpenAIChatBody(model: config.model, messages: messages, stream: stream))
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
      model: config.model,
      max_tokens: maxTokens,
      messages: turns,
      system: system.isEmpty ? nil : system,
      stream: stream
    ))
    return request
  }

  private static func baseRequest(url: String) throws -> URLRequest {
    guard let url = URL(string: url) else {
      throw AIServiceError.invalidConfiguration("Base URL 无法解析（\(url)）")
    }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }
}

private extension AIProviderConfig {
  /// 去掉尾部 / 的 baseURL，供拼接端点路径
  var endpoint: String {
    baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
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
      throw AIServiceError.provider(parsed?.error.message ?? "Anthropic 返回错误")
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
