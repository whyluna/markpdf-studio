import XCTest
@testable import MarkPDF

/// 请求构造与响应解码（FR-AI.4）：OpenAI 兼容 / Anthropic 两协议族
final class AIProviderTests: XCTestCase {
  private let openAIConfig = AIProviderConfig(isEnabled: true, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
  private let anthropicConfig = AIProviderConfig(isEnabled: true, baseURL: "https://api.anthropic.com", model: "claude-3-5-sonnet-latest")

  // MARK: - 请求构造

  func testOpenAIRequest() throws {
    let request = try AIRequestBuilder.chatRequest(
      family: .openAICompatible,
      config: openAIConfig,
      apiKey: "sk-test",
      model: "deepseek-chat",
      messages: [.system("你是助手"), .user("你好")],
      stream: true
    )
    XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
    XCTAssertEqual(body?["model"] as? String, "deepseek-chat")
    XCTAssertEqual(body?["stream"] as? Bool, true)
    let messages = body?["messages"] as? [[String: String]]
    XCTAssertEqual(messages?.count, 2)
    XCTAssertEqual(messages?.first?["role"], "system")
  }

  /// baseURL 尾部斜杠不产生双斜杠
  func testOpenAIRequestTrimsTrailingSlash() throws {
    let config = AIProviderConfig(isEnabled: true, baseURL: "https://api.deepseek.com/v1/", model: "m")
    let request = try AIRequestBuilder.chatRequest(
      family: .openAICompatible, config: config, apiKey: "k", model: "m", messages: [.user("hi")], stream: false
    )
    XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
  }

  /// 多个尾部斜杠全部去除（`https://x.com/v1//` 不再拼出 `//chat/completions`）
  func testMultipleTrailingSlashesStripped() throws {
    let config = AIProviderConfig(isEnabled: true, baseURL: "https://api.deepseek.com/v1//", model: "m")
    let request = try AIRequestBuilder.chatRequest(
      family: .openAICompatible, config: config, apiKey: "k", model: "m", messages: [.user("hi")], stream: false
    )
    XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
  }

  /// 公网 http 拒绝（Bearer Key 不明文出网）；本地回环 http 放行（mock 调试）
  func testPlainHTTPRejectedExceptLoopback() throws {
    let pub = AIProviderConfig(isEnabled: true, baseURL: "http://api.deepseek.com", model: "m")
    XCTAssertThrowsError(
      try AIRequestBuilder.chatRequest(family: .openAICompatible, config: pub, apiKey: "k", model: "m", messages: [.user("hi")], stream: false)
    ) { error in
      guard case .invalidConfiguration = error as? AIServiceError else {
        return XCTFail("期望 invalidConfiguration，实际 \(error)")
      }
    }
    let local = AIProviderConfig(isEnabled: true, baseURL: "http://127.0.0.1:8899", model: "m")
    XCTAssertNoThrow(
      try AIRequestBuilder.chatRequest(family: .openAICompatible, config: local, apiKey: "k", model: "m", messages: [.user("hi")], stream: false)
    )
  }

  func testAnthropicRequest() throws {
    let request = try AIRequestBuilder.chatRequest(
      family: .anthropic,
      config: anthropicConfig,
      apiKey: "sk-ant",
      model: "claude-3-5-sonnet-latest",
      messages: [.system("你是翻译"), .user("第一段"), .assistant("译文"), .user("第二段")],
      stream: true,
      maxTokens: 1024
    )
    XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
    XCTAssertEqual(body?["model"] as? String, "claude-3-5-sonnet-latest")
    XCTAssertEqual(body?["max_tokens"] as? Int, 1024)
    // system 提出为顶层字段，消息体只剩 user/assistant
    XCTAssertEqual(body?["system"] as? String, "你是翻译")
    let messages = body?["messages"] as? [[String: Any]]
    XCTAssertEqual(messages?.count, 3)
    XCTAssertFalse(messages?.contains { $0["role"] as? String == "system" } ?? true)
    // v1.3：assistant 编码为内容块数组（text 块），user 仍为字符串
    let assistantBlocks = messages?[1]["content"] as? [[String: Any]]
    XCTAssertEqual(assistantBlocks?.first?["text"] as? String, "译文")
    XCTAssertEqual(messages?.first?["content"] as? String, "第一段")
  }

  /// 无 system 消息时 body 不携带 system 字段
  func testAnthropicRequestWithoutSystem() throws {
    let request = try AIRequestBuilder.chatRequest(
      family: .anthropic, config: anthropicConfig, apiKey: "k", model: "m", messages: [.user("hi")], stream: false
    )
    let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
    XCTAssertNil(body?["system"])
  }

  func testInvalidBaseURLThrows() {
    let config = AIProviderConfig(isEnabled: true, baseURL: "ht tp://bad url", model: "m")
    XCTAssertThrowsError(
      try AIRequestBuilder.chatRequest(family: .openAICompatible, config: config, apiKey: "k", model: "m", messages: [.user("hi")], stream: false)
    ) { error in
      guard case .invalidConfiguration = error as? AIServiceError else {
        return XCTFail("期望 invalidConfiguration，实际 \(error)")
      }
    }
  }

  // MARK: - 工具调用编码（FR-AI.2 v1.3 agent 循环）

  private let searchTool = AITool(
    name: "workspace_search",
    description: "搜索工作区",
    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
  )

  func testOpenAIToolsEncoding() throws {
    let request = try AIRequestBuilder.chatRequest(
      family: .openAICompatible, config: openAIConfig, apiKey: "k", model: "m",
      messages: [
        .user("找找 attention"),
        AIChatMessage(role: .assistant, content: "", toolCalls: [AIToolCall(id: "call_1", name: "workspace_search", arguments: #"{"query":"attention"}"#)]),
        .toolResult(id: "call_1", content: "命中 2 处"),
      ],
      stream: false, tools: [searchTool]
    )
    let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
    // tools 参数
    let tools = body?["tools"] as? [[String: Any]]
    let function = tools?.first?["function"] as? [String: Any]
    XCTAssertEqual(function?["name"] as? String, "workspace_search")
    XCTAssertNotNil((function?["parameters"] as? [String: Any])?["properties"], "schema 为对象而非字符串")
    // assistant.tool_calls 回传形态
    let messages = body?["messages"] as? [[String: Any]]
    let assistant = messages?[1]
    let calls = assistant?["tool_calls"] as? [[String: Any]]
    XCTAssertEqual(calls?.first?["id"] as? String, "call_1")
    XCTAssertEqual((calls?.first?["function"] as? [String: Any])?["arguments"] as? String, #"{"query":"attention"}"#)
    // role:"tool" 结果消息
    let toolMessage = messages?[2]
    XCTAssertEqual(toolMessage?["role"] as? String, "tool")
    XCTAssertEqual(toolMessage?["tool_call_id"] as? String, "call_1")
    XCTAssertEqual(toolMessage?["content"] as? String, "命中 2 处")
  }

  func testAnthropicToolsEncoding() throws {
    let request = try AIRequestBuilder.chatRequest(
      family: .anthropic, config: anthropicConfig, apiKey: "k", model: "m",
      messages: [
        .user("找找"),
        AIChatMessage(role: .assistant, content: "我来搜索", toolCalls: [
          AIToolCall(id: "tu_1", name: "workspace_search", arguments: #"{"query":"attention"}"#),
          AIToolCall(id: "tu_2", name: "workspace_list_documents", arguments: "{}"),
        ]),
        .toolResult(id: "tu_1", content: "结果一"),
        .toolResult(id: "tu_2", content: "结果二"),
      ],
      stream: false, tools: [searchTool]
    )
    let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
    // tools 用 input_schema 字段名
    let tools = body?["tools"] as? [[String: Any]]
    XCTAssertNotNil(tools?.first?["input_schema"], "Anthropic 字段名为 input_schema")
    let messages = body?["messages"] as? [[String: Any]]
    // assistant content 混排 text + tool_use 块（input 为对象）
    let assistantBlocks = messages?[1]["content"] as? [[String: Any]]
    XCTAssertEqual(assistantBlocks?.first?["type"] as? String, "text")
    XCTAssertEqual(assistantBlocks?[1]["type"] as? String, "tool_use")
    XCTAssertEqual((assistantBlocks?[1]["input"] as? [String: Any])?["query"] as? String, "attention")
    // 连续两个工具结果合并进同一 user 消息（交替校验），块类型 tool_result
    XCTAssertEqual(messages?.count, 3, "两个 tool 结果合并为一条 user")
    let resultBlocks = messages?[2]["content"] as? [[String: Any]]
    XCTAssertEqual(resultBlocks?.count, 2)
    XCTAssertEqual(resultBlocks?.first?["type"] as? String, "tool_result")
    XCTAssertEqual(resultBlocks?.first?["tool_use_id"] as? String, "tu_1")
  }

  // MARK: - 流式增量解码

  func testOpenAIChunkDecoding() throws {
    XCTAssertEqual(try AIChunkDecoder.openAIChunk(from: #"{"choices":[{"delta":{"content":"你好"}}]}"#)?.text, "你好")
    XCTAssertNil(try AIChunkDecoder.openAIChunk(from: #"{"choices":[{"delta":{}}]}"#)?.text)
    XCTAssertNil(try AIChunkDecoder.openAIChunk(from: "[DONE]"))
  }

  func testOpenAIChunkDecodesToolCallDeltas() throws {
    let first = try AIChunkDecoder.openAIChunk(
      from: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"workspace_search","arguments":""}}]}}]}"#
    )
    XCTAssertEqual(first?.toolCallDeltas.first?.id, "call_1")
    XCTAssertEqual(first?.toolCallDeltas.first?.name, "workspace_search")
    let fragment = try AIChunkDecoder.openAIChunk(
      from: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"que"}}]}}]}"#
    )
    XCTAssertEqual(fragment?.toolCallDeltas.first?.argumentsFragment, #"{"que"#)
    let finish = try AIChunkDecoder.openAIChunk(from: #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
    XCTAssertEqual(finish?.finishReason, "tool_calls")
  }

  func testOpenAIErrorPayloadThrows() {
    XCTAssertThrowsError(
      try AIChunkDecoder.openAIChunk(from: #"{"error":{"message":"Insufficient Balance"}}"#)
    ) { error in
      XCTAssertEqual(error as? AIServiceError, .provider("Insufficient Balance"))
    }
  }

  func testAnthropicChunkDecoding() throws {
    let delta = try AIChunkDecoder.anthropicDelta(
      event: "content_block_delta",
      payload: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"世"}}"#
    )
    XCTAssertEqual(delta, .delta("世"))
    XCTAssertEqual(try AIChunkDecoder.anthropicDelta(event: "message_stop", payload: #"{"type":"message_stop"}"#), .finished)
    XCTAssertEqual(try AIChunkDecoder.anthropicDelta(event: "ping", payload: #"{"type":"ping"}"#), .ignored)
  }

  func testAnthropicErrorEventThrows() {
    XCTAssertThrowsError(
      try AIChunkDecoder.anthropicDelta(event: "error", payload: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
    ) { error in
      XCTAssertEqual(error as? AIServiceError, .provider("Overloaded"))
    }
  }

  func testAnthropicToolUseStreamEvents() throws {
    let start = try AIChunkDecoder.anthropicDelta(
      event: "content_block_start",
      payload: #"{"index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"workspace_search","input":{}}}"#
    )
    XCTAssertEqual(start, .toolUseStart(index: 1, id: "tu_1", name: "workspace_search"))
    let delta = try AIChunkDecoder.anthropicDelta(
      event: "content_block_delta",
      payload: #"{"index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#
    )
    XCTAssertEqual(delta, .inputJSONDelta(index: 1, partial: #"{"query":"#))
    // 普通 text 块的 content_block_start 忽略
    let textStart = try AIChunkDecoder.anthropicDelta(
      event: "content_block_start",
      payload: #"{"index":0,"content_block":{"type":"text","text":""}}"#
    )
    XCTAssertEqual(textStart, .ignored)
  }

  // MARK: - 工具调用重组器（v1.3）

  func testOpenAIAccumulatorReassemblesFragments() {
    var accumulator = AIToolCallAccumulator.OpenAI()
    accumulator.ingest([.init(index: 0, id: "call_1", name: "workspace_search", argumentsFragment: "")])
    accumulator.ingest([.init(index: 0, id: nil, name: nil, argumentsFragment: #"{"query":"#)])
    accumulator.ingest([.init(index: 0, id: nil, name: nil, argumentsFragment: #""att"}"#)])
    // 并行第二个调用
    accumulator.ingest([.init(index: 1, id: "call_2", name: "workspace_list_documents", argumentsFragment: "{}")])
    let calls = accumulator.finalize()
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls[0].id, "call_1")
    XCTAssertEqual(calls[0].arguments, #"{"query":"att"}"#)
    XCTAssertEqual(calls[1].name, "workspace_list_documents")
  }

  func testOpenAIAccumulatorDefendsMissingIndex() {
    var accumulator = AIToolCallAccumulator.OpenAI()
    accumulator.ingest([.init(index: 0, id: "call_1", name: "search", argumentsFragment: "{")])
    // 兼容端点缺 index：回退最后槽位继续拼接
    accumulator.ingest([.init(index: nil, id: nil, name: nil, argumentsFragment: "}")])
    XCTAssertEqual(accumulator.finalize().first?.arguments, "{}")
  }

  func testAnthropicAccumulatorReassembles() {
    var accumulator = AIToolCallAccumulator.Anthropic()
    accumulator.blockStart(index: 1, id: "tu_1", name: "workspace_read_section")
    accumulator.ingest(index: 1, partial: #"{"path":"#)
    accumulator.ingest(index: 1, partial: #""a.md"}"#)
    let calls = accumulator.finalize()
    XCTAssertEqual(calls, [AIToolCall(id: "tu_1", name: "workspace_read_section", arguments: #"{"path":"a.md"}"#)])
  }

  func testAccumulatorEmptyArgumentsFallbackToEmptyObject() {
    var accumulator = AIToolCallAccumulator.Anthropic()
    accumulator.blockStart(index: 0, id: "tu_9", name: "workspace_list_documents")
    XCTAssertEqual(accumulator.finalize().first?.arguments, "{}")
  }

  // MARK: - 非流式全量解码

  func testOpenAIFullResponseDecoding() throws {
    let data = Data(#"{"choices":[{"message":{"content":"pong"}}]}"#.utf8)
    XCTAssertEqual(try AIResponseDecoder.openAIMessage(from: data), "pong")
  }

  func testAnthropicFullResponseDecoding() throws {
    let data = Data(#"{"content":[{"type":"text","text":"po"},{"type":"text","text":"ng"}]}"#.utf8)
    XCTAssertEqual(try AIResponseDecoder.anthropicMessage(from: data), "pong")
  }

  func testFullResponseErrorPayloadThrows() {
    let data = Data(#"{"error":{"message":"Invalid API Key"}}"#.utf8)
    XCTAssertThrowsError(try AIResponseDecoder.openAIMessage(from: data)) { error in
      XCTAssertEqual(error as? AIServiceError, .provider("Invalid API Key"))
    }
  }

  // MARK: - 联通性信封校验（连接测试专用）

  /// always-thinking 模型小配额下正文为空属正常：信封完整即通过
  func testOpenAIEnvelopeAcceptsEmptyContent() throws {
    let data = Data(#"{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"length"}]}"#.utf8)
    XCTAssertNoThrow(try AIResponseDecoder.openAICompletionIsWellFormed(data))
  }

  /// 缺 choices（如 Anthropic 形状误配 OpenAI 协议）→ invalidResponse
  func testOpenAIEnvelopeRejectsMissingChoices() {
    let data = Data(#"{"content":[{"type":"text","text":"pong"}]}"#.utf8)
    XCTAssertThrowsError(try AIResponseDecoder.openAICompletionIsWellFormed(data)) { error in
      XCTAssertEqual(error as? AIServiceError, .invalidResponse)
    }
  }

  func testOpenAIEnvelopeErrorPayloadThrows() {
    let data = Data(#"{"error":{"message":"model not found"}}"#.utf8)
    XCTAssertThrowsError(try AIResponseDecoder.openAICompletionIsWellFormed(data)) { error in
      XCTAssertEqual(error as? AIServiceError, .provider("model not found"))
    }
  }

  /// Anthropic 信封：content 允许为空数组（思考耗尽配额）
  func testAnthropicEnvelopeAcceptsEmptyContent() throws {
    let data = Data(#"{"content":[]}"#.utf8)
    XCTAssertNoThrow(try AIResponseDecoder.anthropicCompletionIsWellFormed(data))
  }
}
