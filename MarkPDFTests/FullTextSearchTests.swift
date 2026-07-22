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

  /// PDF 大小上限（保存风暴修复配套）：上限内放行、超限跳过；稀疏文件构造，不占真实磁盘
  func testPDFSizeLimitPureFunction() throws {
    let small = write("small.pdf", "%PDF-1.4\n")
    XCTAssertTrue(FullTextSearch.isPDFWithinSizeLimit(small))
    let big = tempDir.appendingPathComponent("big.pdf")
    FileManager.default.createFile(atPath: big.path, contents: nil)
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: UInt64(FullTextSearch.maxPDFBytes + 1))
    try handle.close()
    XCTAssertFalse(FullTextSearch.isPDFWithinSizeLimit(big))
    // 读取不到大小信息时按不超限处理（交由 PDFDocument 载入失败兜底）
    XCTAssertTrue(FullTextSearch.isPDFWithinSizeLimit(tempDir.appendingPathComponent("missing.pdf")))
  }

  /// 页循环取消（保存风暴修复配套）：按 pdfCancellationCheckInterval 页节奏检查
  func testPDFPageLoopChecksCancellationAtInterval() throws {
    let pdf = try writeBlankPDF("loop.pdf", pages: 100)
    var checks = 0
    let result = FullTextSearch.searchPDF(url: pdf, needle: "词") { checks += 1; return false }
    XCTAssertNil(result)  // 空白 PDF 无文本不命中
    XCTAssertEqual(checks, 100 / FullTextSearch.pdfCancellationCheckInterval)
  }

  /// 页循环取消：首个检查点取消即放弃该文件（返回 nil），不再翻后续页
  func testPDFPageLoopCancelledAtFirstCheckStopsImmediately() throws {
    let pdf = try writeBlankPDF("cancel.pdf", pages: 100)
    var checks = 0
    let result = FullTextSearch.searchPDF(url: pdf, needle: "词") { checks += 1; return true }
    XCTAssertNil(result)
    XCTAssertEqual(checks, 1)
  }

  /// 指定页数的空白 PDF（PDFKit 无法程序化写入文本，仅供循环控制类用例）
  private func writeBlankPDF(_ name: String, pages: Int) throws -> URL {
    let url = tempDir.appendingPathComponent(name)
    let document = PDFDocument()
    for index in 0..<pages { document.insert(PDFPage(), at: index) }
    try XCTUnwrap(document.dataRepresentation()).write(to: url)
    return url
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
