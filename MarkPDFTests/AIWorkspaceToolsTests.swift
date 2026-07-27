import XCTest
@testable import MarkPDF

/// 工作区工具执行器（FR-AI.2 v1.3）：四工具、路径逃逸、截断、错误文案
final class AIWorkspaceToolsTests: XCTestCase {
  private var root: URL!
  private var files: [URL] = []

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIToolsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteA = root.appendingPathComponent("attention.md")
    try "# 原理\nattention mechanism 详解\n\n# 实现\n多头实现细节".write(to: noteA, atomically: true, encoding: .utf8)
    let noteB = root.appendingPathComponent("notes.md")
    try "# 杂记\n无关内容".write(to: noteB, atomically: true, encoding: .utf8)
    files = [noteA, noteB]
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func run(_ name: String, _ argumentsJSON: String) -> String {
    AIWorkspaceTools.execute(
      call: AIToolCall(id: "t", name: name, arguments: argumentsJSON),
      workspaceRoot: root,
      files: files
    )
  }

  func testSearchFindsAndRanks() {
    let result = run("workspace_search", #"{"query":"attention mechanism"}"#)
    XCTAssertTrue(result.contains("attention.md"))
    XCTAssertTrue(result.contains("[L2]"), "带行定位")
    XCTAssertFalse(result.contains("notes.md"), "无命中文件不出现")
  }

  func testSearchNoMatchGuidesRetry() {
    let result = run("workspace_search", #"{"query":"不存在的词组合"}"#)
    XCTAssertTrue(result.contains("No matches"))
  }

  func testSearchMissingQueryReturnsError() {
    XCTAssertTrue(run("workspace_search", "{}").hasPrefix("Error:"))
  }

  func testListDocuments() {
    let result = run("workspace_list_documents", "{}")
    XCTAssertTrue(result.contains("attention.md (md"))
    XCTAssertTrue(result.contains("notes.md"))
  }

  func testOutlineAndReadSection() {
    let outline = run("workspace_get_outline", #"{"path":"attention.md"}"#)
    XCTAssertTrue(outline.contains("[§原理] 原理"))
    XCTAssertTrue(outline.contains("[§实现] 实现"))

    let section = run("workspace_read_section", #"{"path":"attention.md","section":"实现"}"#)
    XCTAssertTrue(section.contains("[§实现] 实现"))
    XCTAssertTrue(section.contains("多头实现细节"))
  }

  func testReadUnknownSectionListsAvailable() {
    let result = run("workspace_read_section", #"{"path":"attention.md","section":"不存在的节"}"#)
    XCTAssertTrue(result.hasPrefix("Error: no section"))
    XCTAssertTrue(result.contains("原理"), "错误里给出可用节名")
  }

  func testPathEscapeRejected() {
    XCTAssertTrue(run("workspace_get_outline", #"{"path":"../outside.md"}"#).hasPrefix("Error:"))
    XCTAssertTrue(run("workspace_get_outline", #"{"path":"/etc/hosts"}"#).hasPrefix("Error:"))
    XCTAssertNil(AIWorkspaceTools.resolvePath("../escape.md", root: root))
    XCTAssertNil(AIWorkspaceTools.resolvePath("sub/../../escape.md", root: root))
    XCTAssertNotNil(AIWorkspaceTools.resolvePath("attention.md", root: root))
  }

  func testUnknownToolAndNoWorkspace() {
    XCTAssertTrue(run("workspace_delete_everything", "{}").hasPrefix("Error: unknown tool"))
    let noRoot = AIWorkspaceTools.execute(
      call: AIToolCall(id: "t", name: "workspace_search", arguments: #"{"query":"x"}"#),
      workspaceRoot: nil, files: []
    )
    XCTAssertTrue(noRoot.contains("no workspace"))
  }

  func testSectionTruncation() throws {
    let big = root.appendingPathComponent("big.md")
    try ("# 大节\n" + String(repeating: "字", count: 8_000)).write(to: big, atomically: true, encoding: .utf8)
    let result = AIWorkspaceTools.execute(
      call: AIToolCall(id: "t", name: "workspace_read_section", arguments: #"{"path":"big.md","section":"大节"}"#),
      workspaceRoot: root, files: [big]
    )
    XCTAssertLessThanOrEqual(result.count, AIWorkspaceTools.sectionCap + 60)
    XCTAssertTrue(result.contains("truncated"))
  }
}
