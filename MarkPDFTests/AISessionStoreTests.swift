import XCTest
@testable import MarkPDF

/// AI 会话落盘（FR-AI.3）：读写回环、损坏抛错、100 条截断、排除名单
final class AISessionStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AISessionStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  func testRoundTrip() throws {
    let sessions = [
      AISessionStore.StoredSession(
        docPath: "papers/a.pdf",
        messages: [
          AISessionStore.StoredMessage(role: "user", content: "问", contextSummary: "文档 a.pdf", promptQuestion: "问", wasCancelled: nil),
          AISessionStore.StoredMessage(role: "assistant", content: "答", contextSummary: nil, promptQuestion: nil, wasCancelled: nil),
        ],
        updatedAt: Date()
      ),
      AISessionStore.StoredSession(docPath: nil, messages: [], updatedAt: Date()),
    ]
    try AISessionStore.save(sessions, workspaceRoot: root)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".markpdf/ai-sessions.json").path))

    let loaded = try AISessionStore.load(workspaceRoot: root)
    XCTAssertEqual(loaded.count, 2)
    XCTAssertEqual(loaded.first?.docPath, "papers/a.pdf")
    XCTAssertEqual(loaded.first?.messages.map(\.content), ["问", "答"])
  }

  func testMissingFileLoadsEmpty() throws {
    XCTAssertEqual(try AISessionStore.load(workspaceRoot: root), [])
  }

  func testCorruptedFileThrows() throws {
    let dir = root.appendingPathComponent(".markpdf")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("ai-sessions.json"))
    XCTAssertThrowsError(try AISessionStore.load(workspaceRoot: root)) { error in
      guard case AISessionStore.StoreError.corrupted = error else {
        return XCTFail("期望 corrupted，实际 \(error)")
      }
    }
  }

  func testMessageCapOnSave() throws {
    let many = (0..<150).map {
      AISessionStore.StoredMessage(role: "user", content: "\($0)", contextSummary: nil, promptQuestion: nil, wasCancelled: nil)
    }
    try AISessionStore.save(
      [AISessionStore.StoredSession(docPath: nil, messages: many, updatedAt: Date())],
      workspaceRoot: root
    )
    let loaded = try AISessionStore.load(workspaceRoot: root)
    XCTAssertEqual(loaded.first?.messages.count, AISessionStore.messageCap)
    XCTAssertEqual(loaded.first?.messages.last?.content, "149", "截断保留最近")
  }

  /// `.markpdf` 在排除名单内（文件树/FSEvents/搜索/反链不触碰）
  func testMarkpdfDirExcluded() {
    XCTAssertTrue(WorkspaceExcludedDirectories.names.contains(".markpdf"))
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/tmp/ws/.markpdf/ai-sessions.json",
      watchedRoot: "/tmp/ws"
    ))
  }
}
