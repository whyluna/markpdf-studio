import XCTest
@testable import MarkPDF

/// AI 助手对话状态机（FR-AI.2）：假传输层驱动流式/取消/重试/错误/历史口径
@MainActor
final class AIChatStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "AIChatStoreTests"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    super.tearDown()
  }

  // MARK: - 工装

  /// OpenAI 兼容 SSE 块
  private func sse(_ text: String) -> Data {
    Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8)
  }

  private var sseDone: Data { Data("data: [DONE]\n\n".utf8) }

  private func makeStore(
    transport: AIServiceTests.MockAITransport,
    hasKey: Bool = true
  ) -> AIChatStore {
    let settings = AISettingsStore(defaults: defaults)
    settings.privacyNoticeAcknowledged = true
    settings.updateConfig(.deepseek) { $0.isEnabled = true }
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    if hasKey { keys.save("sk-test", for: AIProviderKind.deepseek.rawValue) }
    let service = AIService(transport: transport, keys: keys)
    return AIChatStore(settings: settings, service: service)
  }

  private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  // MARK: - 用例

  func testStreamingAggregatesIntoAssistantMessage() async {
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("你"))
        continuation.yield(self.sse("好"))
        continuation.yield(self.sseDone)
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.send("打个招呼")

    let done = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    XCTAssertTrue(done)
    XCTAssertEqual(store.messages[0].role, .user)
    XCTAssertEqual(store.messages[0].content, "打个招呼")
    XCTAssertEqual(store.messages[1].role, .assistant)
    XCTAssertEqual(store.messages[1].content, "你好")
    XCTAssertFalse(store.messages[1].isStreaming)
  }

  func testCancelKeepsPartialTextAndMarks() async {
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("部分"))
        // 不 finish：模拟长回复途中
      }
    })
    let store = makeStore(transport: transport)
    store.send("长问题")
    _ = await waitUntil { store.messages.last?.content.isEmpty == false }

    store.cancel()
    XCTAssertEqual(store.phase, .idle)
    XCTAssertEqual(store.messages.last?.content, "部分")
    XCTAssertEqual(store.messages.last?.wasCancelled, true)
    XCTAssertEqual(store.messages.last?.isStreaming, false)
  }

  func testCancelWithZeroDeltaRemovesEmptyAssistant() async {
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { _ in }  // 永不产出
    })
    let store = makeStore(transport: transport)
    store.send("问题")
    _ = await waitUntil { store.messages.count == 2 }

    store.cancel()
    XCTAssertEqual(store.messages.count, 1, "零增量的空 assistant 应移除（防 Anthropic 400）")
    XCTAssertEqual(store.messages.last?.role, .user)
  }

  func testMissingAPIKeyFails() async {
    let transport = AIServiceTests.MockAITransport()
    let store = makeStore(transport: transport, hasKey: false)
    store.send("问题")

    let failed = await waitUntil {
      if case .failed = store.phase { return true }
      return false
    }
    XCTAssertTrue(failed)
  }

  func testNoProviderFailsImmediately() {
    let settings = AISettingsStore(defaults: defaults)
    settings.privacyNoticeAcknowledged = true
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    let store = AIChatStore(settings: settings, service: AIService(transport: AIServiceTests.MockAITransport(), keys: keys))
    store.send("问题")
    guard case .failed = store.phase else {
      return XCTFail("无 Provider 应立即失败")
    }
    XCTAssertTrue(store.messages.isEmpty)
  }

  func testRetryResendsLastQuestion() async {
    var callCount = 0
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      callCount += 1
      if callCount == 1 {
        return AsyncThrowingStream { $0.finish(throwing: AIServiceError.httpStatus(500, "server error")) }
      }
      return AsyncThrowingStream { continuation in
        continuation.yield(self.sse("成功"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.send("重试我")
    let failed = await waitUntil {
      if case .failed = store.phase { return true }
      return false
    }
    XCTAssertTrue(failed)

    store.retry()
    let done = await waitUntil { store.phase == .idle && store.messages.last?.content == "成功" }
    XCTAssertTrue(done)
    XCTAssertEqual(store.messages.filter { $0.role == .user }.count, 1, "重试不残留旧的失败轮")
    XCTAssertEqual(store.messages.first?.content, "重试我")
  }

  /// 历史轮只送原始问题（上下文只随当轮）：第二轮请求体里第一轮 user 应为原始问题
  func testHistorySendsRawQuestionWithoutContext() async {
    var capturedBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      capturedBodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.contextSources.activeDocument = { _ in (name: "a.md", text: "很长的全文内容") }

    store.send("第一问")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    store.send("第二问")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 4 }

    XCTAssertEqual(capturedBodies.count, 2)
    let second = String(decoding: capturedBodies[1], as: UTF8.self)
    // 当轮（第二问）带 [Document] 标签块；历史轮（第一问）只送原始问题
    XCTAssertTrue(second.contains("[Document: a.md]"))
    XCTAssertTrue(second.contains(#""content":"第一问""#), "历史轮应为原始问题，不重复带全文")
    // user 行留有上下文摘要
    XCTAssertNotNil(store.messages[2].contextSummary)
  }

  func testNewSessionClears() async {
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.send("问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }

    store.newSession()
    XCTAssertTrue(store.messages.isEmpty)
    XCTAssertEqual(store.phase, .idle)
  }
}
