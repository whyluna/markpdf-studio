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
    hasKey: Bool = true,
    configure: ((AISettingsStore) -> Void)? = nil
  ) -> AIChatStore {
    let settings = AISettingsStore(defaults: defaults)
    settings.privacyNoticeAcknowledged = true
    settings.updateConfig(.deepseek) { $0.isEnabled = true }
    configure?(settings)
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

  // MARK: - 会话按文档隔离 + 落盘（FR-AI.3）

  func testThreadsIsolatedPerDocument() async {
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    let docA = URL(fileURLWithPath: "/tmp/ws/a.md")
    let docB = URL(fileURLWithPath: "/tmp/ws/b.pdf")

    store.bindDocument(docA)
    store.send("A 的问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }

    store.bindDocument(docB)
    XCTAssertTrue(store.messages.isEmpty, "B 文档是全新线程")
    XCTAssertEqual(store.activeDocName, "b.pdf")

    store.bindDocument(docA)
    XCTAssertEqual(store.messages.count, 2, "切回 A 恢复原线程")
    XCTAssertEqual(store.messages.first?.content, "A 的问题")
  }

  func testSessionsPersistAcrossWorkspaceReload() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.workspaceDidChange(root: root)
    store.bindDocument(root.appendingPathComponent("note.md"))
    store.send("持久化我")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    store.flush()

    // 新实例模拟重启：载盘 + 绑同文档恢复
    let reopened = makeStore(transport: transport)
    reopened.workspaceDidChange(root: root)
    reopened.bindDocument(root.appendingPathComponent("note.md"))
    XCTAssertEqual(reopened.messages.count, 2)
    XCTAssertEqual(reopened.messages.first?.content, "持久化我")
    XCTAssertEqual(reopened.messages.last?.content, "答")
  }

  func testCorruptedSessionFileSurfacesErrorAndBlocksWrite() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatStoreTests-corrupt-\(UUID().uuidString)")
    let dir = root.appendingPathComponent(".markpdf")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("broken".utf8).write(to: dir.appendingPathComponent("ai-sessions.json"))

    let store = makeStore(transport: AIServiceTests.MockAITransport())
    store.workspaceDidChange(root: root)
    XCTAssertNotNil(store.storageError, "损坏必须可感知（NFR-5）")
    XCTAssertFalse(store.isPersistent, "损坏期间禁写回防覆盖")
    store.flush()
    let data = try Data(contentsOf: dir.appendingPathComponent("ai-sessions.json"))
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "broken", "原文件未被覆盖")
  }

  // MARK: - 结构选节两遍路由（v1.2）

  /// 文档超预算时：第一遍路由选节（非流式），第二遍只带选中节流式作答
  func testOverBudgetDocumentRoutesSections() async {
    var streamBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(
      sendHandler: { _ in
        // 路由第一遍：选第 1 节（结论）
        (Data(#"{"choices":[{"message":{"content":"[1]"}}]}"#.utf8),
         HTTPURLResponse(url: URL(string: "https://x.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      },
      streamHandler: { request in
        streamBodies.append(request.httpBody ?? Data())
        return AsyncThrowingStream { continuation in
          continuation.yield(self.sse("答"))
          continuation.finish()
        }
      }
    )
    // moonshot-v1-8k → 文档预算 4000；构造 5000 字双节文档触发路由
    let store = makeStore(transport: transport) { settings in
      settings.updateConfig(.deepseek) { $0.models = ["moonshot-v1-8k"] }
    }
    let intro = "# 引言\n" + String(repeating: "引", count: 2_500)
    let conclusion = "# 结论\n" + String(repeating: "结", count: 2_500)
    let full = intro + "\n" + conclusion
    store.contextSources.activeDocument = { cap in (name: "paper.md", text: String(full.prefix(cap))) }
    store.contextSources.documentSections = { DocumentSectioner.fromMarkdown(full) }

    store.send("结论是什么")
    let done = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    XCTAssertTrue(done)
    let body = String(decoding: streamBodies.first ?? Data(), as: UTF8.self)
    XCTAssertTrue(body.contains("结结"), "选中的结论节进入上下文")
    XCTAssertFalse(body.contains("引引"), "未选中的引言节被排除（头截时代它必进）")
    XCTAssertTrue(store.messages.first?.contextSummary?.contains("已选 1 节") == true)
  }

  /// 工作区检索层：候选 ≤ 阈值直接全注入（免路由），[Workspace] 块与摘要
  func testWorkspaceCandidatesDirectInjected() async {
    var streamBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      streamBodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport) { settings in
      settings.update { $0.contextIncludeWorkspace = true }
    }
    store.contextSources.workspaceCandidates = { _, completion in
      completion([AIWorkspaceRetriever.Candidate(
        file: "other.md",
        section: DocumentSection(title: "原理", anchor: "§原理", text: "节的完整内容")
      )])
    }

    store.send("问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    let body = String(decoding: streamBodies.first ?? Data(), as: UTF8.self)
    XCTAssertTrue(body.contains("[Workspace]"))
    XCTAssertTrue(body.contains("other.md §原理"))
    XCTAssertTrue(body.contains("节的完整内容"), "注入节全文而非片段")
    XCTAssertTrue(store.messages.first?.contextSummary?.contains("工作区 1 处") == true)
  }

  /// 工作区候选超阈值：先路由选节，仅选中节注入
  func testWorkspaceCandidatesRoutedWhenMany() async {
    var streamBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(
      sendHandler: { _ in
        // 路由：选第 4 节
        (Data(#"{"choices":[{"message":{"content":"[4]"}}]}"#.utf8),
         HTTPURLResponse(url: URL(string: "https://x.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      },
      streamHandler: { request in
        streamBodies.append(request.httpBody ?? Data())
        return AsyncThrowingStream { continuation in
          continuation.yield(self.sse("答"))
          continuation.finish()
        }
      }
    )
    let store = makeStore(transport: transport) { settings in
      settings.update { $0.contextIncludeWorkspace = true }
    }
    store.contextSources.workspaceCandidates = { _, completion in
      completion((0..<6).map {
        AIWorkspaceRetriever.Candidate(
          file: "f.md",
          section: DocumentSection(title: "节\($0)", anchor: "§节\($0)", text: "内容\($0)")
        )
      })
    }

    store.send("问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    let body = String(decoding: streamBodies.first ?? Data(), as: UTF8.self)
    XCTAssertTrue(body.contains("内容4"), "路由选中的节注入")
    XCTAssertFalse(body.contains("内容0"), "未选中节不注入")
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
