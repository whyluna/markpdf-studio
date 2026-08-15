import XCTest
@testable import MarkPDF

/// AI 会话改名/移动跟随（应用内文件树操作）：
/// 全局仓库按路径换键（文件夹后代按前缀平移、目标冲突按时间合并、幂等 no-op）
@MainActor
final class AISessionRekeyTests: XCTestCase {
  private var globalDir: URL!
  private var repositories: [AISessionRepository] = []

  override func setUp() {
    super.setUp()
    globalDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AISessionRekeyTests-\(UUID().uuidString)")
    AISessionStore.globalStoreDirectory = globalDir
  }

  override func tearDown() {
    repositories = []
    try? FileManager.default.removeItem(at: globalDir)
    super.tearDown()
  }

  private func makeRepository() -> AISessionRepository {
    let repository = AISessionRepository()
    repositories.append(repository)
    return repository
  }

  private func seed(
    _ key: String, texts: [String], updatedAt: Date = Date()
  ) -> AISessionStore.StoredSession {
    AISessionStore.StoredSession(
      docPath: key,
      messages: texts.map {
        AISessionStore.StoredMessage(
          role: "user", content: $0, contextSummary: nil, promptQuestion: nil, wasCancelled: nil
        )
      },
      updatedAt: updatedAt
    )
  }

  func testFileRenameRekeysSession() {
    let repository = makeRepository()
    repository.update(seed("/ws/a.md", texts: ["hello"]), for: "/ws/a.md")

    repository.rekey(from: "/ws/a.md", to: "/ws/b.md")

    XCTAssertNil(repository.session(for: "/ws/a.md"), "旧键应清空")
    XCTAssertEqual(repository.session(for: "/ws/b.md")?.messages.map(\.content), ["hello"])
    XCTAssertEqual(repository.session(for: "/ws/b.md")?.docPath, "/ws/b.md")
  }

  func testFolderRenameShiftsDescendantSessions() {
    let repository = makeRepository()
    repository.update(seed("/ws/dir/a.md", texts: ["a"]), for: "/ws/dir/a.md")
    repository.update(seed("/ws/dir/sub/b.md", texts: ["b"]), for: "/ws/dir/sub/b.md")
    repository.update(seed("/ws/other.md", texts: ["o"]), for: "/ws/other.md")

    repository.rekey(from: "/ws/dir", to: "/ws/dir2")

    XCTAssertEqual(repository.session(for: "/ws/dir2/a.md")?.messages.map(\.content), ["a"])
    XCTAssertEqual(repository.session(for: "/ws/dir2/sub/b.md")?.messages.map(\.content), ["b"])
    XCTAssertNil(repository.session(for: "/ws/dir/a.md"))
    XCTAssertNil(repository.session(for: "/ws/dir/sub/b.md"))
    XCTAssertEqual(
      repository.session(for: "/ws/other.md")?.messages.map(\.content), ["o"], "无关会话不动")
  }

  func testRekeyMergesWhenDestinationExists() {
    let repository = makeRepository()
    let older = Date(timeIntervalSince1970: 1000)
    let newer = Date(timeIntervalSince1970: 2000)
    repository.update(seed("/ws/a.md", texts: ["旧线程"]), for: "/ws/a.md")
    repository.update(seed("/ws/b.md", texts: ["目标已有"], updatedAt: older), for: "/ws/b.md")
    repository.update(seed("/ws/a.md", texts: ["旧线程"], updatedAt: newer), for: "/ws/a.md")

    repository.rekey(from: "/ws/a.md", to: "/ws/b.md")

    XCTAssertEqual(
      repository.session(for: "/ws/b.md")?.messages.map(\.content),
      ["目标已有", "旧线程"],
      "目标键已有会话：按 updatedAt 合并，较旧者消息在前"
    )
  }

  func testRekeyIsIdempotent() {
    let repository = makeRepository()
    repository.update(seed("/ws/a.md", texts: ["hello"]), for: "/ws/a.md")

    repository.rekey(from: "/ws/a.md", to: "/ws/b.md")
    repository.rekey(from: "/ws/a.md", to: "/ws/b.md")

    XCTAssertEqual(
      repository.session(for: "/ws/b.md")?.messages.map(\.content), ["hello"],
      "旧键已不存在：第二次调用 no-op（多窗口重复触发无副作用）"
    )
  }
  /// 迁移幂等：归档失败导致下次启动对同一旧文件再迁移时，
  /// 内容完全相同的线程不得重复合并（否则消息逐次翻倍）
  @MainActor
  func testMigrationIsIdempotentWhenArchiveFailed() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MigrateIdem-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // 旧格式工作区存储（相对键）
    try AISessionStore.save([seed("a.md", texts: ["旧问题"], updatedAt: Date(timeIntervalSince1970: 1000))], workspaceRoot: root)

    let first = makeRepository()
    first.migrateWorkspaceStoreIfNeeded(root: root)
    let key = root.standardizedFileURL.resolvingSymlinksInPath()
      .appendingPathComponent("a.md").path
    XCTAssertEqual(first.session(for: key)?.messages.count, 1)

    // 模拟归档失败后的下次启动：旧文件仍在（重新造一份），全局存储已有迁移结果
    try AISessionStore.save([seed("a.md", texts: ["旧问题"], updatedAt: Date(timeIntervalSince1970: 1000))], workspaceRoot: root)
    let second = makeRepository()
    second.migrateWorkspaceStoreIfNeeded(root: root)
    XCTAssertEqual(
      second.session(for: key)?.messages.count, 1,
      "重复迁移同内容线程不得翻倍")

    // 归档成功即落盘（防抖窗口崩溃不丢）：全局文件当下就含迁移线程
    let onDisk = try AISessionStore.loadGlobal()
    XCTAssertTrue(onDisk.contains { $0.docPath == key }, "迁移后应立即落盘")
  }

}
