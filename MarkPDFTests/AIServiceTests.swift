import XCTest
@testable import MarkPDF

/// AIService 门面（FR-AI.4）：假传输层注入，覆盖联通/非流式/流式/错误路径
final class AIServiceTests: XCTestCase {
  /// 假传输层：按注入闭包回放
  struct MockAITransport: AITransport {
    var sendHandler: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    var streamHandler: ((URLRequest) async throws -> AsyncThrowingStream<Data, Error>)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      guard let sendHandler else { throw AIServiceError.invalidResponse }
      return try await sendHandler(request)
    }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
      guard let streamHandler else { throw AIServiceError.invalidResponse }
      return try await streamHandler(request)
    }
  }

  private let deepseekConfig = AIProviderConfig(isEnabled: true, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
  private let anthropicConfig = AIProviderConfig(isEnabled: true, baseURL: "https://api.anthropic.com", model: "claude-3-5-sonnet-latest")

  private func httpResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  @MainActor
  func testCompleteOpenAI() async throws {
    let keyStore = AIKeyStore(storage: InMemoryAIKeyStorage())
    keyStore.save("sk-test", for: AIProviderKind.deepseek.rawValue)
    let transport = MockAITransport { _ in
      (Data(#"{"choices":[{"message":{"content":"pong"}}]}"#.utf8), self.httpResponse(200))
    }
    let service = AIService(transport: transport, keys: keyStore)
    let text = try await service.complete(kind: .deepseek, config: deepseekConfig, model: "deepseek-chat", messages: [.user("ping")])
    XCTAssertEqual(text, "pong")
  }

  @MainActor
  func testStreamAnthropicAggregatesDeltas() async throws {
    let keyStore = AIKeyStore(storage: InMemoryAIKeyStorage())
    keyStore.save("sk-ant", for: AIProviderKind.anthropic.rawValue)
    let sse = """
    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"，世界"}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    let transport = MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(Data(sse.utf8))
        continuation.finish()
      }
    })
    let service = AIService(transport: transport, keys: keyStore)
    var collected = ""
    for try await event in service.stream(kind: .anthropic, config: anthropicConfig, model: "claude-3-5-sonnet-latest", messages: [.user("hi")]) {
      if case .text(let delta) = event { collected += delta }
    }
    XCTAssertEqual(collected, "你好，世界")
  }

  @MainActor
  func testStreamOpenAISkipsDoneSentinel() async throws {
    let keyStore = AIKeyStore(storage: InMemoryAIKeyStorage())
    keyStore.save("sk-test", for: AIProviderKind.deepseek.rawValue)
    let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n"
    let transport = MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(Data(sse.utf8))
        continuation.finish()
      }
    })
    let service = AIService(transport: transport, keys: keyStore)
    var collected = ""
    for try await event in service.stream(kind: .deepseek, config: deepseekConfig, model: "deepseek-chat", messages: [.user("hi")]) {
      if case .text(let delta) = event { collected += delta }
    }
    XCTAssertEqual(collected, "a")
  }

  @MainActor
  func testMissingAPIKeyThrows() async {
    let keyStore = AIKeyStore(storage: InMemoryAIKeyStorage())
    let service = AIService(transport: MockAITransport(), keys: keyStore)
    do {
      _ = try await service.complete(kind: .deepseek, config: deepseekConfig, model: "deepseek-chat", messages: [.user("ping")])
      XCTFail("未配置 Key 应抛 missingAPIKey")
    } catch {
      XCTAssertEqual(error as? AIServiceError, .missingAPIKey)
    }
  }

  @MainActor
  func testHTTPErrorCarriesStatusAndSnippet() async {
    let keyStore = AIKeyStore(storage: InMemoryAIKeyStorage())
    keyStore.save("sk-test", for: AIProviderKind.deepseek.rawValue)
    let transport = MockAITransport { _ in
      (Data(#"{"error":{"message":"unauthorized"}}"#.utf8), self.httpResponse(401))
    }
    let service = AIService(transport: transport, keys: keyStore)
    do {
      _ = try await service.complete(kind: .deepseek, config: deepseekConfig, model: "deepseek-chat", messages: [.user("ping")])
      XCTFail("401 应抛 httpStatus")
    } catch {
      guard case .httpStatus(let status, let snippet) = error as? AIServiceError else {
        return XCTFail("期望 httpStatus，实际 \(error)")
      }
      XCTAssertEqual(status, 401)
      XCTAssertTrue(snippet.contains("unauthorized"))
    }
  }
}
