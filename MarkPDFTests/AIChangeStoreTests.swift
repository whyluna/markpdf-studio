import XCTest
@testable import MarkPDF

/// 变更审查状态机（FR-AI.5）：入队合并、封存、应用/拒绝/撤销状态流转、审查注记
@MainActor
final class AIChangeStoreTests: XCTestCase {
  private var root: URL!

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIChangeStoreTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func editChange(_ path: String, _ edits: (String, String)...) -> AIFileChange {
    AIFileChange(
      kind: .editFile, path: path, content: "",
      edits: edits.map { AIFileChange.TextEdit(oldText: $0.0, newText: $0.1) }
    )
  }

  private func writeFile(_ relative: String, _ text: String) {
    let url = root.appendingPathComponent(relative)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// 全磁盘替身环境（kernel 恒失败 → 走 persistViaStore/直接写盘）
  private func makeEnvironment() -> AIChangeApplier.Environment {
    AIChangeApplier.Environment(
      workspaceRoot: { [weak self] in self?.root },
      trashFile: { url in
        (try? FileManager.default.removeItem(at: url)) != nil
      }
    )
  }

  // MARK: - 入队合并

  func testEnqueueMergesSameFileEditsAndReplacesCreate() {
    let store = AIChangeStore()
    store.enqueue(editChange("a.md", ("旧", "新1")))
    store.enqueue(editChange("b.md", ("x", "y")))
    store.enqueue(editChange("a.md", ("旧2", "新2")))
    store.enqueue(AIFileChange(kind: .createFile, path: "c.md", content: "第一版", edits: []))
    store.enqueue(AIFileChange(kind: .createFile, path: "c.md", content: "第二版", edits: []))

    let sealed = store.sealPending()
    XCTAssertEqual(sealed?.changes.count, 3, "同文件同类合并")
    let aChange = sealed?.changes.first { $0.path == "a.md" }
    XCTAssertEqual(aChange?.edits.count, 2, "editFile 追加块")
    let cChange = sealed?.changes.first { $0.path == "c.md" }
    XCTAssertEqual(cChange?.content, "第二版", "createFile 后提覆盖先提")
    XCTAssertEqual(store.pendingProposalCount, 0, "封存后清零")
  }

  func testSealEmptyReturnsNil() {
    let store = AIChangeStore()
    XCTAssertNil(store.sealPending())
  }

  // MARK: - 应用 / 拒绝 / 撤销流转

  func testApplyHappyPathWritesFilesAndRecordsOutcome() async {
    writeFile("note.md", "# 标题\n\n正文")
    let store = AIChangeStore()
    store.applierEnvironment = makeEnvironment()
    store.enqueue(AIFileChange(kind: .createFile, path: "新建.md", content: "# 新", edits: []))
    store.enqueue(editChange("note.md", ("正文", "修改后正文")))
    guard let sealed = store.sealPending() else { return XCTFail("封存失败") }

    await store.apply(sealed.id)
    let applied = store.changeSet(id: sealed.id)
    guard case .applied(let summary) = applied?.status else { return XCTFail("状态应为 applied") }
    XCTAssertTrue(summary.contains("新建.md"))
    XCTAssertTrue(summary.contains("note.md"))
    XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8), "# 标题\n\n修改后正文")
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("新建.md").path))

    // 审查注记回传模型（应用结果），消费即清
    let notes = store.consumeOutcomeNotes()
    XCTAssertEqual(notes.count, 1)
    XCTAssertTrue(notes[0].contains("APPROVED"))
    XCTAssertTrue(notes[0].contains("edited note.md"))
    XCTAssertTrue(store.consumeOutcomeNotes().isEmpty)
  }

  func testRejectKeepsDiskUntouched() {
    writeFile("note.md", "原")
    let store = AIChangeStore()
    store.applierEnvironment = makeEnvironment()
    store.enqueue(editChange("note.md", ("原", "改")))
    guard let sealed = store.sealPending() else { return XCTFail() }

    store.reject(sealed.id)
    XCTAssertEqual(store.changeSet(id: sealed.id)?.status, .rejected)
    XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8), "原")
    XCTAssertTrue(store.consumeOutcomeNotes()[0].contains("REJECTED"))
  }

  func testUndoRestoresViaCheckpoint() async {
    writeFile("note.md", "版本一")
    let store = AIChangeStore()
    store.applierEnvironment = makeEnvironment()
    store.enqueue(editChange("note.md", ("版本一", "版本二")))
    guard let sealed = store.sealPending() else { return XCTFail() }
    await store.apply(sealed.id)

    await store.undo(sealed.id)
    XCTAssertEqual(store.changeSet(id: sealed.id)?.status, .undone)
    XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8), "版本一")
    // apply 与 undo 各追加一条注记（APPROVED + UNDID）
    let notes = store.consumeOutcomeNotes()
    XCTAssertEqual(notes.count, 2)
    XCTAssertTrue(notes.contains { $0.contains("UNDID") })
    // 二次撤销无效（检查点已清）
    await store.undo(sealed.id)
    XCTAssertEqual(store.changeSet(id: sealed.id)?.status, .undone)
  }

  func testRejectPendingSetsVoidOnWorkspaceSwitch() {
    let store = AIChangeStore()
    store.applierEnvironment = makeEnvironment()
    store.enqueue(AIFileChange(kind: .createFile, path: "a.md", content: "x", edits: []))
    guard let sealed = store.sealPending() else { return XCTFail() }
    store.enqueue(AIFileChange(kind: .createFile, path: "b.md", content: "y", edits: []))

    store.rejectPendingSets()
    XCTAssertEqual(store.changeSet(id: sealed.id)?.status, .rejected, "未审查变更集作废")
    XCTAssertNil(store.sealPending(), "未封存提案一并丢弃")
  }

  func testApplyWithoutEnvironmentIsNoOp() async {
    let store = AIChangeStore()
    store.enqueue(AIFileChange(kind: .createFile, path: "a.md", content: "x", edits: []))
    guard let sealed = store.sealPending() else { return XCTFail() }
    await store.apply(sealed.id)
    XCTAssertEqual(store.changeSet(id: sealed.id)?.status, .pending, "无环境不应用不崩")
  }
}

/// 审查流（FR-AI.6）：审查数据准备、hunk 勾选影响最终落盘内容
final class AIChangeReviewTests: XCTestCase {
  @MainActor
  func testPrepareReviewsAndSelectiveHunkApply() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIReviewTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // 两处相距足够远的变化 → 两个 hunk
    let lines = (1...20).map(String.init)
    let original = lines.joined(separator: "\n") + "\n"
    try original.write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

    let store = AIChangeStore()
    store.applierEnvironment = AIChangeApplier.Environment(
      workspaceRoot: { root },
      trashFile: { url in (try? FileManager.default.removeItem(at: url)) != nil }
    )
    store.enqueue(AIFileChange(
      kind: .editFile, path: "note.md", content: "",
      edits: [
        // 带上下文行确保唯一命中（裸 "2" 会撞 12/20 判多义）
        AIFileChange.TextEdit(oldText: "1\n2\n3", newText: "1\n贰\n3"),
        AIFileChange.TextEdit(oldText: "17\n18\n19", newText: "17\n拾捌\n19"),
      ]))
    guard let sealed = store.sealPending() else { return XCTFail("封存失败") }
    await store.prepareReviewsIfNeeded(sealed.id)

    let updated = store.changeSet(id: sealed.id)!
    let review = try XCTUnwrap(updated.reviews.values.first)
    XCTAssertEqual(review.units.count, 2, "每个编辑块一个变更段（远距修改互不合并）")
    XCTAssertEqual(review.acceptedUnitCount, 2, "默认全接受")
    XCTAssertEqual(review.skippedEditCount, 0)
    XCTAssertFalse(review.units[0].hunk.lines.isEmpty, "段内含 diff")

    // 只保留第二段 → 落盘内容只含 18→拾捌
    let secondID = review.units[1].id
    store.setAllUnits(sealed.id, changeID: updated.set.changes[0].id, accepted: false)
    store.toggleUnit(sealed.id, changeID: updated.set.changes[0].id, unitID: secondID)
    await store.apply(sealed.id)

    let disk = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
    XCTAssertFalse(disk.contains("贰"), "未勾选的第一块不落盘")
    XCTAssertTrue(disk.contains("拾捌"), "勾选的第二块落盘")
    XCTAssertTrue(disk.contains("\n2\n"), "第一块原行保留")

    // 撤销恢复原文
    await store.undo(sealed.id)
    let restored = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
    XCTAssertEqual(restored, original)
  }

  @MainActor
  func testApplyFallsBackWhenBaseDrifted() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIReviewDrift-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "1\n2\n3\n".write(to: root.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)

    let store = AIChangeStore()
    store.applierEnvironment = AIChangeApplier.Environment(
      workspaceRoot: { root },
      trashFile: { url in (try? FileManager.default.removeItem(at: url)) != nil }
    )
    store.enqueue(AIFileChange(kind: .editFile, path: "n.md", content: "", edits: [
      AIFileChange.TextEdit(oldText: "2", newText: "二"),
    ]))
    guard let sealed = store.sealPending() else { return XCTFail() }
    await store.prepareReviewsIfNeeded(sealed.id)
    // 审查期间文件被外部修改（基准漂移；old_text "2" 彻底消失）
    try "1\n五\n3\n".write(to: root.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
    await store.apply(sealed.id)
    // 回退到逐块校验：old_text 不再命中 → 如实失败
    guard case .applied(let summary) = store.changeSet(id: sealed.id)?.status else { return XCTFail() }
    XCTAssertTrue(summary.contains("失败"), "基准漂移且回退校验不中时如实报告：\(summary)")
  }
}

/// 大块提案的变更段拆分（2026-08-19 用户现场：模型把多处修改塞进一个大
/// old_text/new_text → 审查必须按段拆开，逐段勾选）
@MainActor
final class AIReviewUnitSplitTests: XCTestCase {
  func testGiantEditSplitsIntoUnitsAndPartialApply() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("UnitSplit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // 一个大块提案：两处相距远的修改装进同一个 old_text/new_text
    let original = (1...20).map(String.init).joined(separator: "\n") + "\n"
    func rewrite(_ n: Int) -> String { (n == 3 || n == 17) ? "改\(n)" : String(n) }
    let rewritten = (1...20).map(rewrite).joined(separator: "\n") + "\n"
    try original.write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

    let store = AIChangeStore()
    store.applierEnvironment = AIChangeApplier.Environment(
      workspaceRoot: { root },
      trashFile: { url in (try? FileManager.default.removeItem(at: url)) != nil }
    )
    store.enqueue(AIFileChange(kind: .editFile, path: "note.md", content: "", edits: [
      AIFileChange.TextEdit(oldText: original, newText: rewritten),
    ]))
    guard let sealed = store.sealPending() else { return XCTFail() }
    let changeID = try XCTUnwrap(sealed.changes.first?.id)
    await store.prepareReviewsIfNeeded(sealed.id)
    let review = try XCTUnwrap(store.changeSet(id: sealed.id)?.reviews.values.first)
    XCTAssertEqual(review.units.count, 2, "大块内部按变更段拆成两段")

    // 只接受第二段（17→改17）→ 落盘只含第二处修改
    let keepID = review.units[1].id
    store.setAllUnits(sealed.id, changeID: changeID, accepted: false)
    store.toggleUnit(sealed.id, changeID: changeID, unitID: keepID)
    await store.apply(sealed.id)

    let disk = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
    XCTAssertFalse(disk.contains("改3"), "未勾选段不落盘")
    XCTAssertTrue(disk.contains("改17"), "勾选段落盘")
    XCTAssertTrue(disk.contains("\n3\n"), "未勾选段原行保留")
  }
}

/// 卡片持久化（2026-08-19 用户现场：重启后提案卡片消失）：
/// 变更集随会话存取，重启后按原 id 恢复（卡片/回看可用）
@MainActor
final class AIChangePersistenceTests: XCTestCase {
  private var suiteName = "ChangePersist"
  private var defaults: UserDefaults!
  private var globalDir: URL!
  private var repositories: [AISessionRepository] = []

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    globalDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ChangePersist-\(UUID().uuidString)")
    AISessionStore.globalStoreDirectory = globalDir
  }

  override func tearDown() {
    repositories = []
    removeTestDefaultsSuite(suiteName, using: defaults)
    try? FileManager.default.removeItem(at: globalDir)
    AISessionStore.globalStoreDirectory = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MarkPDF", isDirectory: true)
    super.tearDown()
  }

  private func makeChat(
    transport: AIServiceTests.MockAITransport = AIServiceTests.MockAITransport(),
    repository: AISessionRepository
  ) -> AIChatStore {
    let settings = AISettingsStore(defaults: defaults)
    settings.privacyNoticeAcknowledged = true
    settings.updateConfig(.kimi) { $0.isEnabled = true }
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    keys.save("sk-t", for: AIProviderKind.kimi.rawValue)
    let chat = AIChatStore(
      settings: settings,
      service: AIService(transport: transport, keys: keys),
      repository: repository)
    chat.isWritingMode = true
    return chat
  }

  /// 端到端：agent 产卡片 → 落盘 → 全新 store（同仓库）读线程 → 消息引用与变更集都在
  func testChangeCardSurvivesRestartViaSessionStore() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ChangePersist-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let args = "{\"path\":\"note.md\",\"content\":\"# 笔记\"}"
      .replacingOccurrences(of: "\"", with: "\\\"")
    let chunks: [Data] = [
      Data("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"workspace_write_file\",\"arguments\":\"\(args)\"}}]}}]}\n\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n".utf8),
      Data("data: [DONE]\n\n".utf8),
    ]
    var bodies: [Data] = []
    let transport = AIServiceTests.MockAITransport(streamHandler: { request in
      bodies.append(request.httpBody ?? Data())
      return AsyncThrowingStream { continuation in
        if bodies.count == 1 {
          for chunk in chunks { continuation.yield(chunk) }
        } else {
          continuation.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"已提案\"}}]}\n\n".utf8))
          continuation.yield(Data("data: [DONE]\n\n".utf8))
        }
        continuation.finish()
      }
    })
    let repository = AISessionRepository()
    repositories.append(repository)
    let chat = makeChat(transport: transport, repository: repository)
    chat.contextSources.workspaceFiles = { (root: root, files: []) }
    chat.workspaceDidChange(root: root)
    chat.send("写个笔记")
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !(chat.phase == .idle && chat.messages.count >= 2) {
      try await Task.sleep(nanoseconds: 30_000_000)
    }
    let sealedID = chat.messages.last?.changeSetID
    XCTAssertNotNil(sealedID, "消息挂上卡片")
    chat.flush()

    // 重启：全新 chat（同仓库）读同一线程
    let chat2 = makeChat(repository: repository)
    chat2.contextSources.workspaceFiles = { (root: root, files: []) }
    chat2.workspaceDidChange(root: root)
    XCTAssertEqual(chat2.messages.last?.changeSetID, sealedID, "消息的卡片引用往返")
    let sealed = chat2.changeStore.changeSet(id: sealedID!)
    XCTAssertNotNil(sealed, "变更集按原 id 恢复")
    XCTAssertEqual(sealed?.set.changes.first?.path, "note.md")
    XCTAssertEqual(sealed?.status, .pending)
  }

  /// 序列化单元：已应用批次 → JSON 往返 → 恢复后撤销仍能还原磁盘（检查点重建路径）
  func testAppliedSetRoundTripAndUndoAfterRestore() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ChangePersist-undo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "原文".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

    let environment = AIChangeApplier.Environment(
      workspaceRoot: { root },
      trashFile: { url in (try? FileManager.default.removeItem(at: url)) != nil }
    )
    let store = AIChangeStore()
    store.applierEnvironment = environment
    store.enqueue(AIFileChange(kind: .editFile, path: "a.md", content: "", edits: [
      AIFileChange.TextEdit(oldText: "原文", newText: "AI 改写"),
    ]))
    guard let sealed = store.sealPending() else { return XCTFail() }
    await store.prepareReviewsIfNeeded(sealed.id)
    await store.apply(sealed.id)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8), "AI 改写")

    // JSON 往返（模拟重启）
    let stored = store.serializableSets(referencing: [sealed.id])
    let data = try JSONEncoder().encode(stored)
    let decoded = try JSONDecoder().decode([AISessionStore.StoredChangeSet].self, from: data)
    let restored = AIChangeStore()
    restored.applierEnvironment = environment
    restored.restoreSets(decoded)
    let entry = try XCTUnwrap(restored.changeSet(id: sealed.id), "原 id 恢复")
    guard case .applied = entry.status else { return XCTFail("状态应为 applied") }
    XCTAssertFalse(entry.reviews.isEmpty, "审查数据随行")

    // 重启后撤销：检查点按审查基准重建 → 磁盘还原
    await restored.undo(sealed.id)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8), "原文")
    if case .undone = restored.changeSet(id: sealed.id)?.status {} else {
      XCTFail("撤销后状态应为 undone")
    }
  }
}
