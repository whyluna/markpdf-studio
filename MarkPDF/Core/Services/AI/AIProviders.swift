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
    maxTokens: Int = 4096,
    tools: [AITool]? = nil
  ) throws -> URLRequest {
    switch family {
    case .openAICompatible:
      return try openAIRequest(config: config, apiKey: apiKey, model: model, messages: messages, stream: stream, maxTokens: maxTokens, tools: tools)
    case .anthropic:
      return try anthropicRequest(config: config, apiKey: apiKey, model: model, messages: messages, stream: stream, maxTokens: maxTokens, tools: tools)
    }
  }

  /// 工具 schema JSON 字符串 → 对象（送 body 需嵌为对象而非字符串）
  private static func schemaObject(_ json: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
  }

  /// 工具调用 arguments JSON 字符串 → 对象（Anthropic input 需对象；解析失败给空对象）
  private static func argumentsObject(_ json: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
  }

  // MARK: - OpenAI 兼容协议（POST {baseURL}/chat/completions）

  private static func openAIRequest(
    config: AIProviderConfig,
    apiKey: String,
    model: String,
    messages: [AIChatMessage],
    stream: Bool,
    maxTokens: Int,
    tools: [AITool]?
  ) throws -> URLRequest {
    var request = try baseRequest(url: config.endpoint + "/chat/completions")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let encodedMessages: [[String: Any]] = messages.map { message in
      var body: [String: Any] = ["role": message.role.rawValue, "content": message.content]
      if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
        body["tool_calls"] = toolCalls.map { call in
          ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
        }
      }
      if message.role == .tool, let id = message.toolCallID {
        body["tool_call_id"] = id
      }
      return body
    }
    var payload: [String: Any] = [
      "model": model,
      "messages": encodedMessages,
      "stream": stream,
      // 回复上限与 Anthropic 口径统一（当前预设模型族均接受 max_tokens；
      // OpenAI 新模型族改名 max_completion_tokens 属已知偏差，见进度文档）
      "max_tokens": maxTokens,
    ]
    if let tools, !tools.isEmpty {
      payload["tools"] = tools.map { tool in
        ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": schemaObject(tool.parametersJSON)]]
      }
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    return request
  }

  // MARK: - Anthropic Messages API（POST {baseURL}/v1/messages）

  private static func anthropicRequest(
    config: AIProviderConfig,
    apiKey: String,
    model: String,
    messages: [AIChatMessage],
    stream: Bool,
    maxTokens: Int,
    tools: [AITool]?
  ) throws -> URLRequest {
    var request = try baseRequest(url: config.endpoint + "/v1/messages")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    // system 为顶层字段而非消息；多段 system 合并
    let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
    var turns: [[String: Any]] = []
    // Anthropic 严格角色交替校验：连续同角色轮必须合并，否则 400。
    //（历史压缩/摘要注入/会话恢复任何一处产生连续 user/assistant 都可能踩中）
    func appendTurn(role: String, blocks: [[String: Any]]) {
      if var last = turns.last, last["role"] as? String == role,
        var content = last["content"] as? [[String: Any]] {
        content.append(contentsOf: blocks)
        last["content"] = content
        turns[turns.count - 1] = last
      } else {
        turns.append(["role": role, "content": blocks])
      }
    }
    for message in messages where message.role != .system {
      switch message.role {
      case .assistant:
        var blocks: [[String: Any]] = []
        if !message.content.isEmpty {
          blocks.append(["type": "text", "text": message.content])
        }
        for call in message.toolCalls ?? [] {
          blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": argumentsObject(call.arguments)])
        }
        appendTurn(role: "assistant", blocks: blocks.isEmpty ? [["type": "text", "text": ""]] : blocks)
      case .tool:
        // 工具结果进 user 消息的 tool_result 块；连续多个结果合并进同一 user 消息（交替校验）
        let block: [String: Any] = [
          "type": "tool_result",
          "tool_use_id": message.toolCallID ?? "",
          "content": message.content,
        ]
        if var last = turns.last, last["role"] as? String == "user",
          var content = last["content"] as? [[String: Any]],
          content.allSatisfy({ ($0["type"] as? String) == "tool_result" }) {
          content.append(block)
          last["content"] = content
          turns[turns.count - 1] = last
        } else {
          appendTurn(role: "user", blocks: [block])
        }
      default:
        appendTurn(role: "user", blocks: [["type": "text", "text": message.content]])
      }
    }
    var payload: [String: Any] = [
      "model": model,
      "max_tokens": maxTokens,
      "messages": turns,
      "stream": stream,
    ]
    if !system.isEmpty { payload["system"] = system }
    if let tools, !tools.isEmpty {
      payload["tools"] = tools.map { tool in
        ["name": tool.name, "description": tool.description, "input_schema": schemaObject(tool.parametersJSON)]
      }
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
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
  /// OpenAI 兼容流单块解码结果（v1.3：文本与工具调用增量可混排）
  struct OpenAIOutcome: Equatable {
    var text: String?
    var toolCallDeltas: [OpenAIToolCallDelta] = []
    var finishReason: String?
  }

  /// OpenAI 工具调用增量片段：首片带 index/id/name，后续片只有 arguments 碎片
  struct OpenAIToolCallDelta: Equatable {
    let index: Int?
    let id: String?
    let name: String?
    let argumentsFragment: String?
  }

  enum AnthropicOutcome: Equatable {
    case delta(String)
    /// tool_use 内容块开始（携带 id/name；input 经 inputJSONDelta 逐片到达）
    case toolUseStart(index: Int, id: String, name: String)
    /// tool_use 参数 JSON 碎片
    case inputJSONDelta(index: Int, partial: String)
    case finished
    case ignored
  }

  struct OpenAIErrorPayload: Decodable {
    struct ErrorBody: Decodable { let message: String }
    let error: ErrorBody
  }

  private struct OpenAIChunk: Decodable {
    struct Choice: Decodable {
      struct ToolCallDelta: Decodable {
        struct Function: Decodable {
          let name: String?
          let arguments: String?
        }
        let index: Int?
        let id: String?
        let function: Function?
      }
      struct Delta: Decodable {
        let content: String?
        let tool_calls: [ToolCallDelta]?
      }
      let delta: Delta?
      let finish_reason: String?
    }
    let choices: [Choice]
  }

  struct AnthropicErrorPayload: Decodable {
    struct ErrorBody: Decodable { let message: String }
    let error: ErrorBody
  }

  private struct AnthropicContentBlockDelta: Decodable {
    struct Delta: Decodable {
      let type: String?
      let text: String?
      let partial_json: String?
    }
    let index: Int?
    let delta: Delta
  }

  private struct AnthropicContentBlockStart: Decodable {
    struct Block: Decodable {
      let type: String
      let id: String?
      let name: String?
    }
    let index: Int?
    let content_block: Block
  }

  /// OpenAI 兼容流：单个 data 载荷 → 文本/工具增量/结束原因；[DONE] 哨兵返回 nil；error 载荷抛错
  static func openAIChunk(from payload: String) throws -> OpenAIOutcome? {
    if payload == "[DONE]" { return nil }
    guard let data = payload.data(using: .utf8) else { return nil }
    if let error = try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data) {
      throw AIServiceError.provider(error.error.message)
    }
    let chunk: OpenAIChunk
    do {
      chunk = try JSONDecoder().decode(OpenAIChunk.self, from: data)
    } catch {
      throw AIServiceError.invalidResponse
    }
    guard let choice = chunk.choices.first else { return OpenAIOutcome() }
    var outcome = OpenAIOutcome()
    outcome.text = choice.delta?.content
    outcome.finishReason = choice.finish_reason
    outcome.toolCallDeltas = (choice.delta?.tool_calls ?? []).map {
      OpenAIToolCallDelta(index: $0.index, id: $0.id, name: $0.function?.name, argumentsFragment: $0.function?.arguments)
    }
    return outcome
  }

  /// Anthropic 流：event + data → 文本增量/工具块事件/结束/忽略；error 事件抛错
  static func anthropicDelta(event: String?, payload: String) throws -> AnthropicOutcome {
    guard let data = payload.data(using: .utf8) else { return .ignored }
    if event == "error" {
      let parsed = try? JSONDecoder().decode(AnthropicErrorPayload.self, from: data)
      throw AIServiceError.provider(parsed?.error.message ?? String(localized: "Anthropic 返回错误"))
    }
    switch event {
    case "content_block_start":
      guard let parsed = try? JSONDecoder().decode(AnthropicContentBlockStart.self, from: data),
        parsed.content_block.type == "tool_use",
        let id = parsed.content_block.id, let name = parsed.content_block.name
      else { return .ignored }
      return .toolUseStart(index: parsed.index ?? 0, id: id, name: name)
    case "content_block_delta":
      // 与非流式路径同口径：解码失败统一映射 invalidResponse（不把英文 DecodingError 详情抛给 UI）
      let parsed: AnthropicContentBlockDelta
      do {
        parsed = try JSONDecoder().decode(AnthropicContentBlockDelta.self, from: data)
      } catch {
        throw AIServiceError.invalidResponse
      }
      if parsed.delta.type == "input_json_delta" {
        return .inputJSONDelta(index: parsed.index ?? 0, partial: parsed.delta.partial_json ?? "")
      }
      return .delta(parsed.delta.text ?? "")
    case "message_stop":
      return .finished
    default:
      // message_start / content_block_stop / message_delta / ping 等
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
    // 结构解码失败统一映射为 invalidResponse（UI 文案一致，不抛英文 DecodingError 详情）
    let response: OpenAICompletion
    do {
      response = try JSONDecoder().decode(OpenAICompletion.self, from: data)
    } catch {
      throw AIServiceError.invalidResponse
    }
    guard let text = response.choices.first?.message.content, !text.isEmpty else {
      throw AIServiceError.invalidResponse
    }
    return text
  }

  static func anthropicMessage(from data: Data) throws -> String {
    if let error = try? JSONDecoder().decode(AIChunkDecoder.AnthropicErrorPayload.self, from: data) {
      throw AIServiceError.provider(error.error.message)
    }
    let response: AnthropicCompletion
    do {
      response = try JSONDecoder().decode(AnthropicCompletion.self, from: data)
    } catch {
      throw AIServiceError.invalidResponse
    }
    let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
    guard !text.isEmpty else {
      throw AIServiceError.invalidResponse
    }
    return text
  }

  // MARK: - 联通性校验（连接测试专用）

  /// 只验「端点+鉴权+模型能给出结构完整的补全信封」，不验正文非空：
  /// always-thinking 模型（如 Kimi K3）在极小 max_tokens 下思考耗尽配额、
  /// 正文为空属正常响应，误判 invalidResponse 会让连接测试永远失败
  static func openAICompletionIsWellFormed(_ data: Data) throws {
    if let error = try? JSONDecoder().decode(AIChunkDecoder.OpenAIErrorPayload.self, from: data) {
      throw AIServiceError.provider(error.error.message)
    }
    do {
      _ = try JSONDecoder().decode(OpenAICompletion.self, from: data)
    } catch {
      throw AIServiceError.invalidResponse
    }
  }

  /// Anthropic 版信封校验（content 数组存在即可，允许为空）
  static func anthropicCompletionIsWellFormed(_ data: Data) throws {
    if let error = try? JSONDecoder().decode(AIChunkDecoder.AnthropicErrorPayload.self, from: data) {
      throw AIServiceError.provider(error.error.message)
    }
    do {
      _ = try JSONDecoder().decode(AnthropicCompletion.self, from: data)
    } catch {
      throw AIServiceError.invalidResponse
    }
  }
}
