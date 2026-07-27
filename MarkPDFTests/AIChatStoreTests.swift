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
      settings.updateConfig(.deepseek) { $0.modelSpecs = [AIModelSpec(name: "moonshot-v1-8k", contextTokens: 8_000)] }
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

  // MARK: - agent 工具调用循环（v1.3）

  /// SSE：一次 OpenAI 工具调用流（list_documents）
  private var sseToolCallTurn: [Data] {
    [
      Data("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"workspace_list_documents\",\"arguments\":\"\"}}]}}]}\n\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{}\"}}]}}]}\n\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n".utf8),
      Data("data: [DONE]\n\n".utf8),
    ]
  }

  private func makeWorkspace() throws -> (root: URL, files: [URL]) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentLoopTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paper-notes.md")
    try "# 结论\n注意力机制是关键".write(to: note, atomically: true, encoding: .utf8)
    return (root, [note])
  }

  /// 完整循环：首轮模型请求工具 → 执行 → 结果回传 → 次轮流式作答
  func testAgentLoopExecutesToolThenAnswers() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }

    var requestBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      requestBodies.append(request.httpBody ?? Data())
      let isToolTurn = requestBodies.count == 1
      return AsyncThrowingStream { continuation in
        if isToolTurn {
          for chunk in self.sseToolCallTurn { continuation.yield(chunk) }
        } else {
          continuation.yield(self.sse("笔记里提到注意力机制"))
          continuation.yield(self.sseDone)
        }
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport) { settings in
      settings.update { $0.contextIncludeWorkspace = true }
    }
    store.contextSources.workspaceFiles = { (root: workspace.root, files: workspace.files) }

    store.send("工作区里有哪些笔记")
    let done = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    XCTAssertTrue(done)
    XCTAssertEqual(requestBodies.count, 2, "工具轮 + 作答轮共两次请求")
    // 首轮带 tools 定义
    let first = String(decoding: requestBodies[0], as: UTF8.self)
    XCTAssertTrue(first.contains("workspace_search"), "tools 定义送出")
    // 次轮带 assistant(tool_calls) 与工具结果
    let second = String(decoding: requestBodies[1], as: UTF8.self)
    XCTAssertTrue(second.contains("call_1"))
    XCTAssertTrue(second.contains("paper-notes.md"), "工具结果（文件清单）回传")
    // UI：活动 chip 完成态 + 最终回答
    let assistant = store.messages.last
    XCTAssertEqual(assistant?.content, "笔记里提到注意力机制")
    XCTAssertEqual(assistant?.toolActivities.count, 1)
    XCTAssertEqual(assistant?.toolActivities.first?.isRunning, false)
  }

  /// 「工作区」开关关闭：请求不带 tools
  func testWorkspaceOffSendsNoTools() async {
    var requestBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      requestBodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)  // contextIncludeWorkspace 默认 false
    store.send("问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    let body = String(decoding: requestBodies.first ?? Data(), as: UTF8.self)
    XCTAssertFalse(body.contains("\"tools\""))
  }

  /// 同参数重复调用去重：第二次直接回「Duplicate call」不重复执行
  func testDuplicateToolCallDeduped() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }

    var requestBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      requestBodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        if requestBodies.count <= 2 {
          // 前两轮都请求同一工具同一参数
          for chunk in self.sseToolCallTurn { continuation.yield(chunk) }
        } else {
          continuation.yield(self.sse("答"))
          continuation.yield(self.sseDone)
        }
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport) { settings in
      settings.update { $0.contextIncludeWorkspace = true }
    }
    store.contextSources.workspaceFiles = { (root: workspace.root, files: workspace.files) }

    store.send("问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    XCTAssertEqual(requestBodies.count, 3)
    let third = String(decoding: requestBodies[2], as: UTF8.self)
    XCTAssertTrue(third.contains("Duplicate call"), "重复调用返回去重提示")
  }

  // MARK: - 上下文压缩（L2 滚动摘要）

  /// 载入含 rollingSummary 的会话 → 下轮请求历史区注入摘要
  func testRollingSummaryInjectedIntoRequest() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SummaryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try AISessionStore.save([
      AISessionStore.StoredSession(
        docPath: nil,
        messages: [
          AISessionStore.StoredMessage(role: "user", content: "旧问", contextSummary: nil, promptQuestion: "旧问", wasCancelled: nil),
          AISessionStore.StoredMessage(role: "assistant", content: "旧答", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
        ],
        updatedAt: Date(),
        rollingSummary: "早期结论：注意力有效",
        summarizedCount: 2
      )
    ], workspaceRoot: root)

    var requestBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      requestBodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.workspaceDidChange(root: root)
    store.send("新问题")
    _ = await waitUntil { store.phase == .idle && requestBodies.count == 1 }
    let body = String(decoding: requestBodies[0], as: UTF8.self)
    XCTAssertTrue(body.contains("[Earlier conversation summary]"))
    XCTAssertTrue(body.contains("注意力有效"))
    // summarizedCount=2：旧问/旧答不再以原文出现
    XCTAssertFalse(body.contains(#""content":"旧问""#))
  }

  /// 历史超限触发后台压缩：完成后 rollingSummary 落盘
  func testCompactionRunsAndPersists() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CompactTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // 18 条历史（>16 触发压缩）
    var stored: [AISessionStore.StoredMessage] = []
    for index in 0..<9 {
      stored.append(AISessionStore.StoredMessage(role: "user", content: "问\(index)", contextSummary: nil, promptQuestion: "问\(index)", wasCancelled: nil))
      stored.append(AISessionStore.StoredMessage(role: "assistant", content: "答\(index)", contextSummary: nil, promptQuestion: nil, wasCancelled: nil))
    }
    try AISessionStore.save(
      [AISessionStore.StoredSession(docPath: nil, messages: stored, updatedAt: Date())],
      workspaceRoot: root
    )

    let transport = AIServiceTests.MockAITransport(
      sendHandler: { _ in
        // 压缩请求（complete）返回摘要
        (Data(#"{"choices":[{"message":{"content":"压缩摘要：前九轮结论"}}]}"#.utf8),
         HTTPURLResponse(url: URL(string: "https://x.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      },
      streamHandler: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(self.sse("答"))
          continuation.finish()
        }
      }
    )
    let store = makeStore(transport: transport)
    store.workspaceDidChange(root: root)
    store.send("触发压缩的问题")
    _ = await waitUntil { store.phase == .idle }
    // 压缩后台完成 → 落盘含 rollingSummary
    let persisted = await waitUntil {
      store.flush()
      let sessions = (try? AISessionStore.load(workspaceRoot: root)) ?? []
      return sessions.first?.rollingSummary?.contains("压缩摘要") == true
    }
    XCTAssertTrue(persisted)
    let sessions = try AISessionStore.load(workspaceRoot: root)
    XCTAssertGreaterThan(sessions.first?.summarizedCount ?? 0, 0)
  }

  /// 压缩范围 = 滚出保留区的旧增量（v1.4）：近期轮次不进压缩请求，压缩后仍以原文送出
  func testCompactionOnlyCoversRolledOutIncrement() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PreserveTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // 4 轮 × 6000 字 = 24000 字 > 历史预算 16000（deepseek 默认 64k 窗口）触发字符压缩；
    // 保留区 11200 → 最后一轮（问题3号/回答3号）留原文，前三轮滚出并入摘要
    var stored: [AISessionStore.StoredMessage] = []
    for index in 0..<4 {
      let question = "问题\(index)号" + String(repeating: "长", count: 3_000)
      let answer = "回答\(index)号" + String(repeating: "久", count: 3_000)
      stored.append(AISessionStore.StoredMessage(role: "user", content: question, contextSummary: nil, promptQuestion: question, wasCancelled: nil))
      stored.append(AISessionStore.StoredMessage(role: "assistant", content: answer, contextSummary: nil, promptQuestion: nil, wasCancelled: nil))
    }
    try AISessionStore.save(
      [AISessionStore.StoredSession(docPath: nil, messages: stored, updatedAt: Date())],
      workspaceRoot: root
    )

    var compactionBodies: [Data] = []
    var streamBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(
      sendHandler: { request in
        compactionBodies.append(request.httpBody ?? Data())
        return (Data(#"{"choices":[{"message":{"content":"压缩摘要：前三轮结论"}}]}"#.utf8),
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
    let store = makeStore(transport: transport)
    store.workspaceDidChange(root: root)
    store.send("第一问")
    _ = await waitUntil { store.phase == .idle }
    let compacted = await waitUntil {
      store.flush()
      let sessions = (try? AISessionStore.load(workspaceRoot: root)) ?? []
      return sessions.first?.rollingSummary?.contains("压缩摘要") == true
    }
    XCTAssertTrue(compacted)

    // 压缩请求只含滚出的前三轮，不含保留区最后一轮
    let compactionBody = String(decoding: compactionBodies.first ?? Data(), as: UTF8.self)
    XCTAssertTrue(compactionBody.contains("问题0号"))
    XCTAssertTrue(compactionBody.contains("问题2号"))
    XCTAssertFalse(compactionBody.contains("问题3号"), "保留区轮次不进压缩")

    // 压缩后下一轮请求：保留区原文 + 摘要注入；被压部分不再以原文出现
    store.send("第二问")
    _ = await waitUntil { store.phase == .idle && streamBodies.count == 2 }
    let second = String(decoding: streamBodies.last ?? Data(), as: UTF8.self)
    XCTAssertTrue(second.contains("问题3号"), "保留区消息仍以原文送出")
    XCTAssertTrue(second.contains("[Earlier conversation summary]"))
    XCTAssertFalse(second.contains("问题0号"), "被压部分不以原文出现")
  }

  /// 锚点代码级兜底：压缩回复漏锚点 → 落盘摘要末尾补 Anchors mentioned 行
  func testCompactionAppendsMissingAnchors() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AnchorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // 18 条短消息走条数触发，被压的第一轮含锚点；mock 摘要不含锚点
    var stored: [AISessionStore.StoredMessage] = []
    for index in 0..<9 {
      let answer = index == 0 ? "结论在 [§Methods] 与 [p.5]" : "答\(index)"
      stored.append(AISessionStore.StoredMessage(role: "user", content: "问\(index)", contextSummary: nil, promptQuestion: "问\(index)", wasCancelled: nil))
      stored.append(AISessionStore.StoredMessage(role: "assistant", content: answer, contextSummary: nil, promptQuestion: nil, wasCancelled: nil))
    }
    try AISessionStore.save(
      [AISessionStore.StoredSession(docPath: nil, messages: stored, updatedAt: Date())],
      workspaceRoot: root
    )

    let transport = AIServiceTests.MockAITransport(
      sendHandler: { _ in
        (Data(#"{"choices":[{"message":{"content":"摘要没带锚点"}}]}"#.utf8),
         HTTPURLResponse(url: URL(string: "https://x.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      },
      streamHandler: { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(self.sse("答"))
          continuation.finish()
        }
      }
    )
    let store = makeStore(transport: transport)
    store.workspaceDidChange(root: root)
    store.send("触发压缩")
    _ = await waitUntil { store.phase == .idle }
    let fixed = await waitUntil {
      store.flush()
      let sessions = (try? AISessionStore.load(workspaceRoot: root)) ?? []
      return sessions.first?.rollingSummary?.contains("Anchors mentioned: [§Methods], [p.5]") == true
    }
    XCTAssertTrue(fixed, "漏掉的锚点由代码补全")
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
