import XCTest
@testable import MarkPDF

/// 文件回链解析与路径解析（FR-5.3）
final class MarkdownFileLinkTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownFileLinkTests.\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  // MARK: - parse

  func testParsePlainPdf() {
    XCTAssertEqual(MarkdownFileLink.parse("论文.pdf"), .init(path: "论文.pdf", page: nil))
  }

  func testParseWithPage() {
    XCTAssertEqual(MarkdownFileLink.parse("papers/论文.pdf#page=3"), .init(path: "papers/论文.pdf", page: 3))
  }

  func testParsePercentEncoded() {
    XCTAssertEqual(
      MarkdownFileLink.parse("%E8%AE%BA%E6%96%87.pdf#page=12"),
      .init(path: "论文.pdf", page: 12)
    )
  }

  func testParseRejectsExternalSchemes() {
    XCTAssertNil(MarkdownFileLink.parse("https://example.com/a.pdf#page=3"))
    XCTAssertNil(MarkdownFileLink.parse("data:text/plain,xx"))
    XCTAssertNil(MarkdownFileLink.parse("mailto:a@b.com"))
  }

  func testParseRejectsEmptyPath() {
    XCTAssertNil(MarkdownFileLink.parse("#page=3"))
  }

  func testParseIgnoresNonPageFragment() {
    XCTAssertEqual(MarkdownFileLink.parse("a.pdf#section-x"), .init(path: "a.pdf", page: nil))
  }

  // MARK: - resolve

  func testResolveRelativeToDocumentDir() {
    let docDir = tempDir.appendingPathComponent("notes")
    let pdf = tempDir.appendingPathComponent("papers/论文.pdf")
    try? FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data().write(to: pdf)
    let resolved = MarkdownFileLink.resolve(
      path: "../papers/论文.pdf", documentDir: docDir, workspaceRoot: tempDir)
    XCTAssertEqual(resolved?.standardizedFileURL, pdf.standardizedFileURL)
  }

  func testResolveFallsBackToWorkspaceRoot() {
    let docDir = tempDir.appendingPathComponent("notes/deep")
    let pdf = tempDir.appendingPathComponent("papers/论文.pdf")
    try? FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data().write(to: pdf)
    // md 目录下不存在，回退到工作区根目录解析
    let resolved = MarkdownFileLink.resolve(
      path: "papers/论文.pdf", documentDir: docDir, workspaceRoot: tempDir)
    XCTAssertEqual(resolved?.standardizedFileURL, pdf.standardizedFileURL)
  }

  func testResolveAbsolute() {
    let pdf = tempDir.appendingPathComponent("论文.pdf")
    try? Data().write(to: pdf)
    XCTAssertEqual(MarkdownFileLink.resolve(path: pdf.path, documentDir: nil, workspaceRoot: nil), pdf)
  }

  func testResolveMissingReturnsNil() {
    XCTAssertNil(
      MarkdownFileLink.resolve(path: "不存在.pdf", documentDir: tempDir, workspaceRoot: tempDir))
  }
}
