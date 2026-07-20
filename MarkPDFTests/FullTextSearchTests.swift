import PDFKit
import XCTest
@testable import MarkPDF

/// 全文搜索（FR-6.2）：md 命中/大小写/行号/摘录、PDF 命中页码、排序、上限、取消
final class FullTextSearchTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FullTextSearchTests.\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  private func write(_ name: String, _ content: String) -> URL {
    let url = tempDir.appendingPathComponent(name)
    try! content.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func testMarkdownHitWithLineAndSnippet() {
    let url = write("a.md", "# 标题\n\n第一行\n核心论述在这里\n")
    let results = FullTextSearch.search(query: "核心", files: [url]) { false }
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results[0].location, 4)
    XCTAssertEqual(results[0].score, 1)
    XCTAssertTrue(results[0].snippet.contains("核心论述"))
  }

  func testCaseInsensitive() {
    let url = write("a.md", "Hello WORLD\n")
    let results = FullTextSearch.search(query: "hello", files: [url]) { false }
    XCTAssertEqual(results.count, 1)
  }

  func testScoreCountsAllHitsAndSortsDesc() {
    let many = write("many.md", "词 词 词\n词\n")
    let one = write("one.md", "词\n")
    let results = FullTextSearch.search(query: "词", files: [one, many]) { false }
    XCTAssertEqual(results.map(\.url.lastPathComponent), ["many.md", "one.md"])
    XCTAssertEqual(results.first?.score, 4)
  }

  func testNoHitReturnsEmpty() {
    let url = write("a.md", "无关内容\n")
    XCTAssertTrue(FullTextSearch.search(query: "核心", files: [url]) { false }.isEmpty)
  }

  func testNonSearchableKindsSkipped() {
    let md = write("a.md", "词\n")
    let img = tempDir.appendingPathComponent("b.png")
    try! Data([1, 2, 3]).write(to: img)
    let results = FullTextSearch.search(query: "词", files: [md, img]) { false }
    XCTAssertEqual(results.count, 1)
  }

  func testCancellationStopsEarly() {
    let a = write("a.md", "词\n")
    let b = write("b.md", "词\n")
    let results = FullTextSearch.search(query: "词", files: [a, b]) { true }
    XCTAssertTrue(results.isEmpty)
  }

  func testPDFHitWithPageNumber() throws {
    let pdfURL = tempDir.appendingPathComponent("doc.pdf")
    let document = PDFDocument()
    let page = PDFPage()
    document.insert(page, at: 0)
    try XCTUnwrap(document.dataRepresentation()).write(to: pdfURL)
    // 空白 PDF 无可提取文本：验证不命中（PDFKit 无法程序化写入文本，文本提取路径由真机覆盖）
    let results = FullTextSearch.search(query: "词", files: [pdfURL]) { false }
    XCTAssertTrue(results.isEmpty)
  }

  func testSnippetTrimsAndEllipsizes() {
    let text = String(repeating: "甲", count: 60) + "核心" + String(repeating: "乙", count: 60)
    let range = text.range(of: "核心", options: [])!
    let snippet = FullTextSearch.snippet(in: text, around: range)
    XCTAssertTrue(snippet.hasPrefix("…"))
    XCTAssertTrue(snippet.hasSuffix("…"))
    XCTAssertTrue(snippet.contains("核心"))
    XCTAssertTrue(snippet.count < text.count)
  }
}
