import XCTest
@testable import MarkPDF

/// AI 助手对话状态机（FR-AI.2）：假传输层驱动流式/取消/重试/错误/历史口径
@MainActor
final class AIChatStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var globalDir: URL!
  /// 会话仓库（AIChatStore 持弱引用，测试需强持有）
  private var repositories: [AISessionRepository] = []

  override func setUp() {
    super.setUp()
    suiteName = "AIChatStoreTests"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
    // 全局会话存储隔离到临时目录（v1.5 唯一落盘位置，防测试污染真实 Application Support）
    globalDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatStoreTests-global-\(UUID().uuidString)")
    AISessionStore.globalStoreDirectory = globalDir
  }

  override func tearDown() {
    repositories = []
    removeTestDefaultsSuite(suiteName, using: defaults)
    try? FileManager.default.removeItem(at: globalDir)
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
    repository: AISessionRepository? = nil,
    configure: ((AISettingsStore) -> Void)? = nil
  ) -> AIChatStore {
    let settings = AISettingsStore(defaults: defaults)
    settings.privacyNoticeAcknowledged = true
    settings.updateConfig(.deepseek) { $0.isEnabled = true }
    configure?(settings)
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    if hasKey { keys.save("sk-test", for: AIProviderKind.deepseek.rawValue) }
    let service = AIService(transport: transport, keys: keys)
    // 不传仓库时新建一个（新实例 = 重新读盘，模拟重启）；同进程多窗口传入同一实例
    return AIChatStore(settings: settings, service: service, repository: repository ?? makeRepository())
  }

  /// 仓库实例（测试强持有；AIChatStore 侧为弱引用）
  private func makeRepository() -> AISessionRepository {
    let repository = AISessionRepository()
    repositories.append(repository)
    return repository
  }

  /// 预置一条工作区通用线程到全局存储（压缩用例的历史夹具；键 = 工作区根路径）
  private func seedWorkspaceThread(
    root: URL,
    messages: [AISessionStore.StoredMessage],
    rollingSummary: String? = nil,
    summarizedCount: Int? = nil
  ) throws {
    try AISessionStore.saveGlobal([
      AISessionStore.StoredSession(
        docPath: AIChatStore.threadKey(for: root),
        messages: messages,
        updatedAt: Date(),
        rollingSummary: rollingSummary,
        summarizedCount: summarizedCount
      )
    ])
  }

  /// 读回工作区通用线程
  private func loadWorkspaceThread(root: URL) -> AISessionStore.StoredSession? {
    let key = AIChatStore.threadKey(for: root)
    return ((try? AISessionStore.loadGlobal()) ?? []).first { $0.docPath == key }
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

  /// 应用内改名/移动：内存线程与激活键随路径平移，随后 bindDocument(新 URL) 幂等不抹内容
  func testRekeySessionsFollowsFileRename() {
    let repository = makeRepository()
    let oldURL = URL(fileURLWithPath: "/ws/a.md")
    let newURL = URL(fileURLWithPath: "/ws/b.md")
    repository.update(
      AISessionStore.StoredSession(
        docPath: AIChatStore.threadKey(for: oldURL),
        messages: [
          AISessionStore.StoredMessage(
            role: "user", content: "改名前的对话",
            contextSummary: nil, promptQuestion: nil, wasCancelled: nil
          ),
        ],
        updatedAt: Date()
      ),
      for: AIChatStore.threadKey(for: oldURL)
    )
    let store = makeStore(transport: AIServiceTests.MockAITransport(), repository: repository)
    store.bindDocument(oldURL)
    XCTAssertEqual(store.messages.map(\.content), ["改名前的对话"])

    store.rekeySessions(from: oldURL, to: newURL)

    XCTAssertEqual(store.activeDocName, "b.md", "激活线程键已平移到新路径")
    XCTAssertEqual(store.messages.map(\.content), ["改名前的对话"], "改名不丢当前对话")
    XCTAssertNil(repository.session(for: AIChatStore.threadKey(for: oldURL)))
    XCTAssertNotNil(repository.session(for: AIChatStore.threadKey(for: newURL)))

    store.bindDocument(newURL)  // 标签联动随后触发：命中同键幂等返回
    XCTAssertEqual(store.messages.map(\.content), ["改名前的对话"], "幂等返回，不重载成空线程")
  }

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

  // MARK: - 全局会话存储（v1.5 方案 A：线程跟文件走，集中存全局文件）

  /// 工作区内文件的线程也写全局存储，不再写 `.markpdf/ai-sessions.json`
  func testAllThreadsPersistToGlobalStoreOnly() async throws {
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
    let file = root.appendingPathComponent("note.md")
    store.bindDocument(file)
    store.send("工作区内的问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    store.flush()

    XCTAssertEqual(
      try AISessionStore.loadGlobal().map(\.docPath),
      [AIChatStore.threadKey(for: file)],
      "工作区内文件的线程也集中存全局（同一文件经不同工作区层级打开不再分叉）"
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: AISessionStore.fileURL(workspaceRoot: root).path),
      "不再写工作区 .markpdf 会话文件"
    )
  }

  /// 外部打开（工作区外）的线程同样进全局存储
  func testExternalThreadPersistsToGlobalStore() async throws {
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.workspaceDidChange(root: nil)
    let externalFile = URL(fileURLWithPath: "/tmp/external-\(UUID().uuidString).pdf")
    store.bindDocument(externalFile)
    store.send("外部文档的问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    store.flush()

    XCTAssertEqual(
      try AISessionStore.loadGlobal().map(\.docPath),
      [AIChatStore.threadKey(for: externalFile)]
    )
  }

  /// 同一文件经不同工作区层级打开：读到同一条线程（用户实测的分叉缺口）
  func testSameFileAcrossWorkspaceLevelsSharesThread() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatStoreTests-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = nested.appendingPathComponent("paper.pdf")

    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    // 祖先目录为工作区时聊
    let outer = makeStore(transport: transport)
    outer.workspaceDidChange(root: root)
    outer.bindDocument(file)
    outer.send("在祖先工作区聊的")
    _ = await waitUntil { outer.phase == .idle && outer.messages.count == 2 }
    outer.flush()

    // 改以子目录为工作区（新实例 = 重启）：同一文件续上，不分叉
    let inner = makeStore(transport: transport)
    inner.workspaceDidChange(root: nested)
    inner.bindDocument(file)
    XCTAssertEqual(
      inner.messages.map(\.content),
      ["在祖先工作区聊的", "答"],
      "会话是文件的属性：换工作区层级仍是同一条线程"
    )
  }

  /// 两个窗口各聊各自文件：共享仓库整体写出，互不清空
  func testTwoWindowsPersistBothThreads() async throws {
    let repository = makeRepository()
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let fileA = URL(fileURLWithPath: "/tmp/windowA-\(UUID().uuidString).md")
    let fileB = URL(fileURLWithPath: "/tmp/windowB-\(UUID().uuidString).md")
    let windowA = makeStore(transport: transport, repository: repository)
    let windowB = makeStore(transport: transport, repository: repository)
    windowA.bindDocument(fileA)
    windowA.send("A 窗口")
    _ = await waitUntil { windowA.phase == .idle && windowA.messages.count == 2 }
    windowB.bindDocument(fileB)
    windowB.send("B 窗口")
    _ = await waitUntil { windowB.phase == .idle && windowB.messages.count == 2 }
    windowA.flush()
    windowB.flush()

    let keys = Set(try AISessionStore.loadGlobal().compactMap(\.docPath))
    XCTAssertEqual(
      keys,
      [AIChatStore.threadKey(for: fileA), AIChatStore.threadKey(for: fileB)],
      "多窗口线程互不覆盖"
    )
  }

  /// 无工作区时全局线程照常载入（外部打开启动即续）
  func testGlobalThreadLoadsWithoutWorkspace() throws {
    let file = URL(fileURLWithPath: "/tmp/ext-\(UUID().uuidString).pdf")
    try AISessionStore.saveGlobal(
      [
        AISessionStore.StoredSession(
          docPath: AIChatStore.threadKey(for: file),
          messages: [
            AISessionStore.StoredMessage(role: "user", content: "上次聊的", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
          ],
          updatedAt: Date()
        ),
      ]
    )

    let store = makeStore(transport: AIServiceTests.MockAITransport())
    store.workspaceDidChange(root: nil)
    store.bindDocument(file)
    XCTAssertEqual(store.messages.map(\.content), ["上次聊的"], "无工作区也能从全局存储续上")
    XCTAssertTrue(store.isPersistent, "文件线程始终持久（会话跟文件走）")
  }

  /// 无工作区窗口的「工作区通用」线程为内存态（无归属文件，不落盘）
  func testWorkspaceGeneralThreadWithoutWorkspaceIsMemoryOnly() async {
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.workspaceDidChange(root: nil)
    XCTAssertFalse(store.isPersistent, "无工作区的通用线程不持久（面板提示依据）")
    store.send("草稿问题")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    store.flush()
    XCTAssertTrue(((try? AISessionStore.loadGlobal()) ?? []).isEmpty, "内存态不落盘")
  }

  // MARK: - 旧版工作区存储迁移（v1.5）

  /// 旧格式（相对 key + 通用线程）迁入全局存储，原文件归档
  func testLegacyWorkspaceStoreMigratesToGlobal() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try AISessionStore.save(
      [
        AISessionStore.StoredSession(
          docPath: "note.md",
          messages: [
            AISessionStore.StoredMessage(role: "user", content: "旧记录", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
            AISessionStore.StoredMessage(role: "assistant", content: "旧答", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
          ],
          updatedAt: Date()
        ),
        AISessionStore.StoredSession(
          docPath: nil,  // 旧版工作区通用线程
          messages: [
            AISessionStore.StoredMessage(role: "user", content: "通用线程", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
          ],
          updatedAt: Date()
        ),
      ],
      workspaceRoot: root
    )

    let store = makeStore(transport: AIServiceTests.MockAITransport())
    store.workspaceDidChange(root: root)
    store.bindDocument(root.appendingPathComponent("note.md"))
    XCTAssertEqual(store.messages.map(\.content), ["旧记录", "旧答"], "相对 key 迁移后同文档线程可见")

    store.flush()
    let keys = Set(try AISessionStore.loadGlobal().compactMap(\.docPath))
    XCTAssertTrue(keys.contains(AIChatStore.threadKey(for: root.appendingPathComponent("note.md"))))
    XCTAssertTrue(keys.contains(AIChatStore.threadKey(for: root)), "旧通用线程键迁为工作区根路径")
    // 原文件归档：不再二次迁移且数据可回溯
    XCTAssertFalse(FileManager.default.fileExists(atPath: AISessionStore.fileURL(workspaceRoot: root).path))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(".markpdf/ai-sessions.migrated.json").path
    ))
  }

  /// 迁移合并：同一文件双键（相对 + 绝对）按 updatedAt 先后合并，摘要下标平移
  func testMigrationMergesConflictingKeys() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.md")
    try AISessionStore.save(
      [
        AISessionStore.StoredSession(
          docPath: "note.md",
          messages: [
            AISessionStore.StoredMessage(role: "user", content: "旧1", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
            AISessionStore.StoredMessage(role: "assistant", content: "旧2", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
          ],
          updatedAt: Date(timeIntervalSince1970: 1_000),
          rollingSummary: "旧摘要",
          summarizedCount: 1
        ),
        AISessionStore.StoredSession(
          docPath: AIChatStore.threadKey(for: file),
          messages: [
            AISessionStore.StoredMessage(role: "user", content: "新1", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
          ],
          updatedAt: Date(timeIntervalSince1970: 1_000.001),  // 微秒级相近（真实双键同批写盘形态）
          rollingSummary: "新摘要",
          summarizedCount: 1
        ),
      ],
      workspaceRoot: root
    )

    let store = makeStore(transport: AIServiceTests.MockAITransport())
    store.workspaceDidChange(root: root)
    store.bindDocument(file)
    XCTAssertEqual(store.messages.map(\.content), ["旧1", "旧2", "新1"], "较旧线程消息在前")

    store.flush()
    let merged = try XCTUnwrap(
      try AISessionStore.loadGlobal().first { $0.docPath == AIChatStore.threadKey(for: file) }
    )
    XCTAssertEqual(merged.rollingSummary, "新摘要", "摘要沿用较新一方")
    XCTAssertEqual(merged.summarizedCount, 3, "覆盖下标按旧者消息数平移（1 + 2）")
  }

  /// 启动时序竞态：标签恢复先绑文档（线程尚空）、工作区后载入触发迁移——
  /// 激活线程必须补上迁入的历史，且不得把仓库记录覆盖成空（2026-07-27 实锤丢数据）
  func testMigrationDoesNotStompActiveThread() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("note.md")
    try AISessionStore.save(
      [
        AISessionStore.StoredSession(
          docPath: "note.md",
          messages: [
            AISessionStore.StoredMessage(role: "user", content: "迁移进来的", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
          ],
          updatedAt: Date(timeIntervalSince1970: 1_000)
        ),
      ],
      workspaceRoot: root
    )

    let store = makeStore(transport: AIServiceTests.MockAITransport())
    store.bindDocument(file)  // 先绑文档（模拟标签恢复先于工作区载入的启动时序）
    XCTAssertTrue(store.messages.isEmpty)
    store.workspaceDidChange(root: root)

    XCTAssertEqual(store.messages.map(\.content), ["迁移进来的"], "激活线程补上迁入的历史")
    store.flush()
    let persisted = try XCTUnwrap(
      try AISessionStore.loadGlobal().first { $0.docPath == AIChatStore.threadKey(for: file) }
    )
    XCTAssertEqual(persisted.messages.map(\.content), ["迁移进来的"], "不得被空态覆盖")
  }

  func testThreadKeyHelpers() {
    let root = URL(fileURLWithPath: "/tmp/ws")
    XCTAssertEqual(
      AISessionRepository.migratedKey(for: "papers/a.pdf", root: root),
      URL(fileURLWithPath: "/tmp/ws/papers/a.pdf").resolvingSymlinksInPath().path
    )
    XCTAssertEqual(
      AISessionRepository.migratedKey(for: nil, root: root),
      AIChatStore.threadKey(for: root),
      "旧通用线程 → 工作区根路径"
    )
    XCTAssertEqual(AIChatStore.workspaceThreadKey(for: nil), "", "无工作区通用线程为空串（内存态）")
  }

  func testCorruptedGlobalStoreSurfacesErrorAndBlocksWrite() throws {
    try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
    let globalFile = AISessionStore.globalFileURL()
    try Data("broken".utf8).write(to: globalFile)

    let repository = makeRepository()
    XCTAssertTrue(repository.isBroken, "损坏必须可感知（NFR-5）")
    XCTAssertNotNil(repository.storageError)
    let store = makeStore(transport: AIServiceTests.MockAITransport(), repository: repository)
    store.bindDocument(URL(fileURLWithPath: "/tmp/whatever.md"))
    XCTAssertFalse(store.isPersistent, "损坏期间禁写回防覆盖")
    store.flush()
    XCTAssertEqual(
      String(decoding: try Data(contentsOf: globalFile), as: UTF8.self),
      "broken",
      "原文件未被覆盖"
    )
  }

  /// 旧工作区文件损坏：提示但不阻断（全局存储照常工作），且不归档以便用户自查
  func testCorruptedLegacyStoreSurfacesErrorWithoutArchiving() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChatStoreTests-corrupt-\(UUID().uuidString)")
    let dir = root.appendingPathComponent(".markpdf")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("broken".utf8).write(to: dir.appendingPathComponent("ai-sessions.json"))

    let store = makeStore(transport: AIServiceTests.MockAITransport())
    store.workspaceDidChange(root: root)
    XCTAssertNotNil(store.storageError, "损坏必须可感知（NFR-5）")
    let data = try Data(contentsOf: dir.appendingPathComponent("ai-sessions.json"))
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "broken", "原文件未被覆盖或归档")
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
    // 首轮带 tools 定义与使用纪律
    let first = String(decoding: requestBodies[0], as: UTF8.self)
    XCTAssertTrue(first.contains("workspace_search"), "tools 定义送出")
    XCTAssertTrue(first.contains("Tool guidelines:"), "工具使用纪律入 system")
    // 次轮带 assistant(tool_calls) 与工具结果 + 状态行
    let second = String(decoding: requestBodies[1], as: UTF8.self)
    XCTAssertTrue(second.contains("call_1"))
    XCTAssertTrue(second.contains("paper-notes.md"), "工具结果（文件清单）回传")
    XCTAssertTrue(second.contains("[Status] turn 1"), "状态行并入最后一个工具结果尾部")
    XCTAssertTrue(second.contains("tool calls used"), "状态行含调用计数（JSON 会把 / 转义故不整串断言）")
    // UI：活动 chip 完成态 + 最终回答
    let assistant = store.messages.last
    XCTAssertEqual(assistant?.content, "笔记里提到注意力机制")
    XCTAssertEqual(assistant?.toolActivities.count, 1)
    XCTAssertEqual(assistant?.toolActivities.first?.isRunning, false)
  }

  /// FR-AI.5：写工具产提案——循环内入队不落盘，结束封存挂卡片；写作纪律入 system
  func testWriteToolProducesSealedChangeSet() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }

    // 参数按 OpenAI 流式形态整段给出（accumulator 支持单块到达）；
    // 嵌入外层 SSE JSON 前先转义反斜杠再转义引号（内层 \n 保持字面量）
    let args = "{\"path\":\"ai-note.md\",\"content\":\"# AI 笔记\\n\\n- [p.1] 摘录\"}"
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let writeToolChunks: [Data] = [
      Data("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_w\",\"function\":{\"name\":\"workspace_write_file\",\"arguments\":\"\(args)\"}}]}}]}\n\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n".utf8),
      Data("data: [DONE]\n\n".utf8),
    ]

    var requestBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      requestBodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        if requestBodies.count == 1 {
          for chunk in writeToolChunks { continuation.yield(chunk) }
        } else {
          continuation.yield(self.sse("已提案"))
          continuation.yield(self.sseDone)
        }
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport) { settings in
      settings.update { $0.contextIncludeWorkspace = true }
    }
    store.isWritingMode = true
    store.contextSources.workspaceFiles = { (root: workspace.root, files: workspace.files) }

    store.send("帮我写一份笔记")
    let done = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    XCTAssertTrue(done)

    // 写作纪律 + 方言速查入 system；写工具定义送出
    let first = String(decoding: requestBodies[0], as: UTF8.self)
    XCTAssertTrue(first.contains("workspace_write_file"), "写工具定义送出")
    XCTAssertTrue(first.contains("WRITE MODE is ON"), "写作模式指令入 system")
    XCTAssertTrue(first.contains("Never invent image paths"), "图片存在性规则入 system")
    XCTAssertTrue(first.contains("[TOC]"), "方言速查入 system")

    // 工具结果 = 已入待审清单（未落盘）
    let second = String(decoding: requestBodies[1], as: UTF8.self)
    XCTAssertTrue(second.contains("Queued for review"), "提案入队回执回传模型")

    // 文件未落盘；提案封存并挂到 assistant 消息
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("ai-note.md").path),
      "审查前绝不写盘")
    XCTAssertEqual(store.changeStore.sealedSets.count, 1)
    XCTAssertEqual(store.changeStore.sealedSets.first?.set.changes.first?.path, "ai-note.md")
    XCTAssertEqual(store.messages.last?.changeSetID, store.changeStore.sealedSets.first?.id, "卡片挂到最后一条 assistant")
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
    try AISessionStore.saveGlobal([
      AISessionStore.StoredSession(
        docPath: AIChatStore.threadKey(for: root),
        messages: [
          AISessionStore.StoredMessage(role: "user", content: "旧问", contextSummary: nil, promptQuestion: "旧问", wasCancelled: nil),
          AISessionStore.StoredMessage(role: "assistant", content: "旧答", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
        ],
        updatedAt: Date(),
        rollingSummary: "早期结论：注意力有效",
        summarizedCount: 2
      )
    ])

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
    try seedWorkspaceThread(root: root, messages: stored)

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
      return self.loadWorkspaceThread(root: root)?.rollingSummary?.contains("压缩摘要") == true
    }
    XCTAssertTrue(persisted)
    XCTAssertGreaterThan(loadWorkspaceThread(root: root)?.summarizedCount ?? 0, 0)
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
    try seedWorkspaceThread(root: root, messages: stored)

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
      return self.loadWorkspaceThread(root: root)?.rollingSummary?.contains("压缩摘要") == true
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
    try seedWorkspaceThread(root: root, messages: stored)

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
      return self.loadWorkspaceThread(root: root)?.rollingSummary?
        .contains("Anchors mentioned: [§Methods], [p.5]") == true
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

  /// 流式途中切换工作区：必须走完整收尾（finalize + phase 复位），
  /// 否则面板永久卡「回答中」、send 被 phase 守卫永远拦截
  func testWorkspaceChangeDuringStreamingResetsPhase() async {
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("部分"))
        // 不 finish：模拟长回复途中
      }
    })
    let store = makeStore(transport: transport)
    store.send("长问题")
    _ = await waitUntil { store.messages.last?.content.isEmpty == false }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WSChange-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    store.workspaceDidChange(root: root)

    XCTAssertEqual(store.phase, .idle, "切换工作区后不得停留在 streaming")
    XCTAssertTrue(
      store.messages.allSatisfy { !$0.isStreaming },
      "任何消息都不得停在流式态（新线程为空也满足）")

    // 发送不被拦截（守卫 phase != .streaming 已解开）：新线程出现该问题的 user 消息
    store.send("新问题")
    let sent = await waitUntil { store.messages.contains { $0.role == .user && $0.promptQuestion == "新问题" } }
    XCTAssertTrue(sent, "切换后应能继续发送")
  }

  /// 工具执行期间取消：不得再发起新一轮 HTTP 请求（detached 工具不受取消传播，
  /// 返回后必须补查，否则取消语义不即时还白耗一次配额）
  func testCancelDuringToolExecutionSendsNoExtraRequest() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }

    var requestCount = 0
    // mock 每轮都回工具调用：取消闸缺失时循环会继续挂新工具活动/发新请求
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      requestCount += 1
      return AsyncThrowingStream { continuation in
        for chunk in self.sseToolCallTurn { continuation.yield(chunk) }
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport) { settings in
      settings.update { $0.contextIncludeWorkspace = true }
    }
    store.contextSources.workspaceFiles = { (root: workspace.root, files: workspace.files) }

    store.send("工作区里有哪些笔记")
    // 等首个工具活动 chip 出现（工具即将/正在执行），此刻取消
    let chip = await waitUntil { store.messages.last?.toolActivities.isEmpty == false }
    XCTAssertTrue(chip)
    store.cancel()
    // chip 计数在循环内同步递增（无滞后）：取消后必须冻结，否则说明循环仍在继续
    let frozenChips = store.messages.last?.toolActivities.count ?? 0
    // 请求计数滞后一拍（独立请求任务）：先给在途任务落定窗口再取冻结值
    try? await Task.sleep(nanoseconds: 200_000_000)
    let frozenRequests = requestCount
    try? await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertEqual(
      store.messages.last?.toolActivities.count ?? 0, frozenChips,
      "取消后循环不得再挂新的工具活动（无取消闸时每轮都挂）")
    XCTAssertEqual(requestCount, frozenRequests, "取消后不得再发起新一轮请求")
    XCTAssertEqual(store.phase, .idle)
  }

  /// 改名撞上已有会话的文件：内存线程表与仓库合并结果不被 persistNow 盲写覆盖
  func testRekeyMergesWithRepositoryOnlySession() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("RekeyMerge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileA = root.appendingPathComponent("a.md")
    let fileB = root.appendingPathComponent("b.md")
    try "a".write(to: fileA, atomically: true, encoding: .utf8)
    try "b".write(to: fileB, atomically: true, encoding: .utf8)

    let repository = makeRepository()
    // b.md 在仓库里有旧会话（本窗内存未缓存）
    let older = AISessionStore.StoredSession(
      docPath: AIChatStore.threadKey(for: fileB),
      messages: [
        AISessionStore.StoredMessage(
          role: "user", content: "b 的旧问题", contextSummary: nil, promptQuestion: "b 的旧问题", wasCancelled: nil
        )
      ],
      updatedAt: Date(timeIntervalSince1970: 1000)
    )
    repository.update(older, for: AIChatStore.threadKey(for: fileB))
    repository.flush()

    // 当前线程绑定 a.md 并产生一条消息
    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport, repository: repository)
    store.workspaceDidChange(root: root)
    store.bindDocument(fileA)
    store.send("a 的问题")
    _ = await waitUntil { store.messages.count == 2 && store.phase == .idle }

    // 应用内改名 a.md → b.md（撞上已有会话的文件）
    store.rekeySessions(from: fileA, to: fileB)
    store.flush()

    // 仓库里 b.md 的会话必须是合并结果（b 旧消息在前），而非被 a 的单侧副本覆盖
    let merged = repository.session(for: AIChatStore.threadKey(for: fileB))
    XCTAssertEqual(
      merged?.messages.map(\.content),
      ["b 的旧问题", "a 的问题", "答"],
      "改名冲突：目标文件的原有会话不得丢失")
  }
}

/// 写作模式门控（2026-08-19 重设计）：写工具只在面板开关打开时下发；
/// 写作模式下零提案的口头幻觉被显式标记
@MainActor
final class AIWritingModeTests: XCTestCase {
  private var suiteName = "AIWritingModeTests"
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    super.tearDown()
  }

  private func makeStore(transport: AIServiceTests.MockAITransport) -> AIChatStore {
    let settings = AISettingsStore(defaults: defaults)
    settings.privacyNoticeAcknowledged = true
    settings.updateConfig(.kimi) { $0.isEnabled = true }
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    keys.save("sk-test", for: AIProviderKind.kimi.rawValue)
    return AIChatStore(settings: settings, service: AIService(transport: transport, keys: keys), repository: AISessionRepository())
  }

  private func sse(_ text: String) -> Data {
    Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8)
  }

  private var sseDone: Data { Data("data: [DONE]\n\n".utf8) }

  private func waitUntil(
    timeout: TimeInterval = 3, _ condition: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  /// 模式关：有工作区也不下发写工具（纯问答）
  func testWriteToolsAbsentWhenModeOff() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WriteModeOff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var bodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      bodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.yield(self.sseDone)
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.isWritingMode = false
    store.contextSources.workspaceFiles = { (root: root, files: []) }
    store.send("写个笔记")
    _ = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    let body = String(decoding: bodies.first ?? Data(), as: UTF8.self)
    XCTAssertFalse(body.contains("workspace_write_file"), "模式关 = 写工具不下发")
  }

  /// 写作模式开、模型纯文字作答（幻觉「已提交」）：消息被显式标记零提案
  func testWritingModeTextOnlyAnswerFlagged() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WriteModeHallu-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let transport = AIServiceTests.MockAITransport(streamHandler: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(self.sse("我已重新提出修改，请批准"))
        continuation.yield(self.sseDone)
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.isWritingMode = true
    store.contextSources.workspaceFiles = { (root: root, files: []) }
    store.send("重新提交修改")
    let done = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    XCTAssertTrue(done)
    XCTAssertEqual(store.messages.last?.writingNoProposal, true, "零提案的口头声明被标记")
    XCTAssertNil(store.messages.last?.changeSetID)
  }

  /// 单次 edit 工具里部分 old_text 冲突时，保留有效块形成审查卡；旧行为因 1 个
  /// 模糊匹配丢掉全部有效修改，并把失败活动错误画成成功对勾。
  func testWritingModeQueuesMatchedEditsWhenOneEditIsAmbiguous() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WriteModePartial-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("note.md")
    try "# 唯一标题\n重复\n重复\n".write(to: note, atomically: true, encoding: .utf8)

    let rawArgs = ##"{"path":"note.md","edits":[{"old_text":"# 唯一标题","new_text":"# 简明标题"},{"old_text":"重复","new_text":"简化"}]}"##
    let escapedArgs = rawArgs
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let toolChunks: [Data] = [
      Data("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_partial\",\"function\":{\"name\":\"workspace_edit_file\",\"arguments\":\"\(escapedArgs)\"}}]}}]}\n\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n".utf8),
      sseDone,
    ]
    var requestBodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      requestBodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        if requestBodies.count == 1 {
          for chunk in toolChunks { continuation.yield(chunk) }
        } else {
          continuation.yield(self.sse("已提交有效修改，请审批"))
          continuation.yield(self.sseDone)
        }
        continuation.finish()
      }
    })
    let store = makeStore(transport: transport)
    store.isWritingMode = true
    store.contextSources.workspaceFiles = { (root: root, files: [note]) }

    store.send("把文档改简单")
    let done = await waitUntil { store.phase == .idle && store.messages.count == 2 }

    XCTAssertTrue(done)
    XCTAssertEqual(requestBodies.count, 2)
    XCTAssertTrue(
      String(decoding: requestBodies[1], as: UTF8.self).contains("Queued for review (partial)"),
      "部分成功结果须回传模型，避免它误称全部完成")
    let sealed = try XCTUnwrap(store.changeStore.sealedSets.first)
    XCTAssertEqual(sealed.set.changes.first?.edits.count, 1, "有效块进入审查卡，模糊块跳过")
    XCTAssertEqual(sealed.set.changes.first?.edits.first?.newText, "# 简明标题")
    XCTAssertEqual(store.messages.last?.changeSetID, sealed.id)
    XCTAssertEqual(store.messages.last?.writingNoProposal, false)
    XCTAssertEqual(store.messages.last?.toolActivities.first?.isPartialSuccess, true)
    XCTAssertFalse(try String(contentsOf: note, encoding: .utf8).contains("简明标题"), "审批前不落盘")
  }

  func testFailedToolActivityIsNotReportedAsSuccess() {
    var activity = AIChatStore.ToolActivity(name: "workspace_edit_file", argsSummary: "note.md")
    activity.isRunning = false
    activity.resultSummary = "Error: all 2 edits failed to match 'note.md'."
    XCTAssertTrue(activity.hasFailed)
    XCTAssertFalse(activity.isPartialSuccess)
  }
}

/// 多文档并行运行（2026-08-19 用户需求）：切文档不取消在途运行；
/// 两个文档各自提问各自完成，互不干扰
@MainActor
final class AIParallelRunTests: XCTestCase {
  private var suiteName = "AIParallelRunTests"
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    super.tearDown()
  }

  private func makeStore(transport: AIServiceTests.MockAITransport) -> AIChatStore {
    let settings = AISettingsStore(defaults: defaults)
    settings.privacyNoticeAcknowledged = true
    settings.updateConfig(.kimi) { $0.isEnabled = true }
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    keys.save("sk-t", for: AIProviderKind.kimi.rawValue)
    return AIChatStore(settings: settings, service: AIService(transport: transport, keys: keys), repository: AISessionRepository())
  }

  private func sse(_ text: String) -> Data {
    Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8)
  }

  private var sseDone: Data { Data("data: [DONE]\n\n".utf8) }

  private func waitUntil(
    timeout: TimeInterval = 5, _ condition: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  func testSwitchingTabsDoesNotCancelAndRunsAreParallel() async throws {
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      return AsyncThrowingStream { continuation in
        if body.contains("问题A") {
          // A 延迟应答：给切文档 + B 提问留出时间窗
          Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            continuation.yield(self.sse("A 的回答"))
            continuation.yield(self.sseDone)
            continuation.finish()
          }
        } else {
          continuation.yield(self.sse("B 的回答"))
          continuation.yield(self.sseDone)
          continuation.finish()
        }
      }
    })
    let store = makeStore(transport: transport)
    let docA = URL(fileURLWithPath: "/tmp/parallel/a.md")
    let docB = URL(fileURLWithPath: "/tmp/parallel/b.md")

    store.bindDocument(docA)
    store.send("问题A")
    XCTAssertEqual(store.phase, .streaming)

    // A 在跑时切到 B：不取消，A 的消息不再显示
    store.bindDocument(docB)
    XCTAssertTrue(store.messages.isEmpty, "B 是新线程")
    XCTAssertEqual(store.phase, .idle, "B 没有运行，面板空闲可提问")

    // B 提问（与 A 并行），B 立即回答
    store.send("问题B")
    let bDone = await waitUntil { store.phase == .idle && store.messages.count == 2 }
    XCTAssertTrue(bDone)
    XCTAssertEqual(store.messages.last?.content, "B 的回答")

    // 切回 A：后台运行的 A 已完成并写回原线程
    store.bindDocument(docA)
    let aDone = await waitUntil { store.messages.count == 2 && store.messages.last?.content == "A 的回答" }
    XCTAssertTrue(aDone, "切走不取消，A 的回答照常写回")
    XCTAssertEqual(store.messages.first?.content, "问题A")
  }

  func testStopOnlyCancelsActiveThreadRun() async throws {
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      return AsyncThrowingStream { continuation in
        if body.contains("问题A") {
          Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            continuation.yield(self.sse("A 的回答"))
            continuation.yield(self.sseDone)
            continuation.finish()
          }
        } else {
          continuation.yield(self.sse("B 的回答"))
          continuation.yield(self.sseDone)
          continuation.finish()
        }
      }
    })
    let store = makeStore(transport: transport)
    let docA = URL(fileURLWithPath: "/tmp/parallel2/a.md")
    let docB = URL(fileURLWithPath: "/tmp/parallel2/b.md")

    store.bindDocument(docA)
    store.send("问题A")
    store.bindDocument(docB)
    // B 上没有运行：cancel 是空操作，不影响 A
    store.cancel()
    store.bindDocument(docA)
    let aDone = await waitUntil { store.messages.count == 2 && store.messages.last?.content == "A 的回答" }
    XCTAssertTrue(aDone, "在别的线程点停止不影响 A 的运行")
  }
}

/// 写作模式独立 max_tokens（v2.1 用户决策）：与问答分开，写大文件不被问答额度截断
@MainActor
final class AIWritingTokensTests: XCTestCase {
  private var suiteName = "AIWritingTokensTests"
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    super.tearDown()
  }

  private func sse(_ text: String) -> Data {
    Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8)
  }

  private var sseDone: Data { Data("data: [DONE]\n\n".utf8) }

  func testWritingModeUsesDedicatedTokenBudget() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WritingTokens-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let settings = AISettingsStore(defaults: defaults)
    settings.privacyNoticeAcknowledged = true
    settings.updateConfig(.kimi) { config in
      config.isEnabled = true
      // 大窗口模型：避免独立额度被「窗口一半」夹取，验证设置值直达请求
      config.modelSpecs = [AIModelSpec(name: "moonshot-v1-8k", contextTokens: 64_000)]
    }
    settings.update { $0.chatMaxReplyTokens = 3_000; $0.writingMaxReplyTokens = 9_999 }
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    keys.save("sk-t", for: AIProviderKind.kimi.rawValue)
    var bodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      bodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        continuation.yield(self.sse("答"))
        continuation.yield(self.sseDone)
        continuation.finish()
      }
    })
    let store = AIChatStore(settings: settings, service: AIService(transport: transport, keys: keys), repository: AISessionRepository())
    store.contextSources.workspaceFiles = { (root: root, files: []) }

    // 写作模式：用独立额度
    store.isWritingMode = true
    store.send("写")
    _ = await { () -> Bool in
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if store.phase == .idle, store.messages.count == 2 { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return false
    }()
    let writingBody = String(decoding: bodies.last ?? Data(), as: UTF8.self)
    XCTAssertTrue(writingBody.contains("9999"), "写作模式送 writingMaxReplyTokens：\(writingBody.prefix(200))")

    // 问答模式：用普通额度
    store.isWritingMode = false
    store.send("问")
    _ = await { () -> Bool in
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if store.messages.count == 4 { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return false
    }()
    let chatBody = String(decoding: bodies.last ?? Data(), as: UTF8.self)
    XCTAssertTrue(chatBody.contains("3000"), "问答送 chatMaxReplyTokens")
  }
}

/// 新会话必须丢弃旧运行尚未封存的写提案，不能挂到下一次回答。
@MainActor
final class AINewSessionProposalIsolationTests: XCTestCase {
  func testNewSessionDiscardsOnlyActiveThreadPendingProposals() {
    let suite = "AINewSessionProposalIsolation-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AISettingsStore(defaults: defaults)
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    let repository = AISessionRepository()
    let store = AIChatStore(
      settings: settings,
      service: AIService(transport: AIServiceTests.MockAITransport(), keys: keys),
      repository: repository)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("new-session-\(UUID().uuidString)")
    store.workspaceDidChange(root: root)
    let activeKey = AIChatStore.workspaceThreadKey(for: root)
    store.changeStore.enqueue(
      AIFileChange(kind: .createFile, path: "stale.md", content: "旧任务", edits: []),
      bucket: activeKey)
    store.changeStore.enqueue(
      AIFileChange(kind: .createFile, path: "other.md", content: "并行任务", edits: []),
      bucket: "other-thread")

    store.newSession()

    XCTAssertNil(store.changeStore.sealPending(bucket: activeKey), "旧会话提案必须清空")
    XCTAssertNotNil(store.changeStore.sealPending(bucket: "other-thread"), "其它并行文档不受影响")
  }
}
