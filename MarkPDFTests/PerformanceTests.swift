import PDFKit
import XCTest
@testable import MarkPDF

/// 性能体检（NFR/FR 指标，M4 里程碑例检）：
/// NFR-1 100 页 PDF 打开 < 1s；FR-3.4 500 页全文搜索 < 2s；FR-6.1 万级文件模糊搜索 < 100ms；
/// FR-1.1 千文件目录树遍历 < 500ms。
final class PerformanceTests: XCTestCase {
  private let pdf100 = URL(fileURLWithPath: "/tmp/perf/test100.pdf")
  private let pdf500 = URL(fileURLWithPath: "/tmp/perf/test500.pdf")
  private let searchDir = URL(fileURLWithPath: "/tmp/perf/wssearch")

  /// NFR-1：100 页 PDF 打开 < 1s（PDFDocument 载入 + 首页可用）
  func testOpen100PagePDFUnder1s() throws {
    try XCTSkipUnless(FileManager.default.fileExists(atPath: pdf100.path), "缺少夹具 /tmp/perf/test100.pdf")
    let start = Date()
    let doc = try XCTUnwrap(PDFDocument(url: pdf100))
    XCTAssertNotNil(doc.page(at: 0))
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 1.0, "100 页打开 \(elapsed)s 超过 1s")
  }

  /// FR-3.4：500 页 PDF 全文搜索 < 2s
  func testSearch500PagePDFUnder2s() throws {
    try XCTSkipUnless(FileManager.default.fileExists(atPath: pdf500.path), "缺少夹具 /tmp/perf/test500.pdf")
    let start = Date()
    let results = FullTextSearch.search(query: "分页", files: [pdf500]) { false }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertFalse(results.isEmpty)
    XCTAssertLessThan(elapsed, 2.0, "500 页搜索 \(elapsed)s 超过 2s")
  }

  /// FR-6.1：万级文件名模糊匹配 < 100ms
  func testFuzzyMatch10kUnder100ms() {
    let candidates = (1...10000).map { "workspace-dir-\($0)/笔记-\($0).md" }
    let start = Date()
    var hits = 0
    // 查询预处理一次、全体候选复用（与面板实际调用路径一致）
    let prepared = FuzzyMatcher.prepare("笔记")
    for name in candidates {
      if FuzzyMatcher.match(prepared, in: name) != nil { hits += 1 }
    }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertGreaterThan(hits, 0)
    XCTAssertLessThan(elapsed, 0.1, "万级模糊匹配 \(elapsed)s 超过 100ms")
  }

  /// FR-1.1 代理指标：千文件目录枚举遍历 < 500ms（扫描核心路径的 IO 部分）
  func testEnumerate1000FilesUnder500ms() throws {
    let dir = URL(fileURLWithPath: "/tmp/perf/ws1000")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path), "缺少夹具 /tmp/perf/ws1000")
    let fm = FileManager.default
    let start = Date()
    func walk(_ url: URL, depth: Int) -> Int {
      guard depth < 12 else { return 0 }
      var isDir: ObjCBool = false
      fm.fileExists(atPath: url.path, isDirectory: &isDir)
      guard isDir.boolValue else { return 1 }
      let urls = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
      return urls.reduce(0) { $0 + walk($1, depth: depth + 1) }
    }
    let count = walk(dir, depth: 0)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(count, 1000)
    XCTAssertLessThan(elapsed, 0.5, "千文件遍历 \(elapsed)s 超过 500ms")
  }

  /// FR-6.2：200 个 md 全文搜索（工作区全文搜索常见规模）
  func testFullTextSearch200Files() throws {
    try XCTSkipUnless(FileManager.default.fileExists(atPath: searchDir.path), "缺少夹具 /tmp/perf/wssearch")
    let files = (1...200).map { searchDir.appendingPathComponent("doc\($0).md") }
    let start = Date()
    let results = FullTextSearch.search(query: "分页", files: files) { false }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertFalse(results.isEmpty)
    // 宽松阈值：200×~10KB 文件应远小于 1s
    XCTAssertLessThan(elapsed, 1.0, "200 文件搜索 \(elapsed)s 超过 1s")
  }
}
