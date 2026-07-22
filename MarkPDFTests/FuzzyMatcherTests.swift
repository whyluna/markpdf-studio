import XCTest
@testable import MarkPDF

/// FR-6.1 模糊匹配单测
final class FuzzyMatcherTests: XCTestCase {
  func testSubsequenceMatch() {
    XCTAssertNotNil(FuzzyMatcher.match(FuzzyMatcher.prepare("vllm"), in: "vllm.pdf"))
    XCTAssertNotNil(FuzzyMatcher.match(FuzzyMatcher.prepare("vp"), in: "vllm.pdf"))
    XCTAssertNotNil(FuzzyMatcher.match(FuzzyMatcher.prepare("组汇"), in: "组会汇报.md"))
  }

  func testNonMatch() {
    XCTAssertNil(FuzzyMatcher.match(FuzzyMatcher.prepare("xyz"), in: "vllm.pdf"))
    XCTAssertNil(FuzzyMatcher.match(FuzzyMatcher.prepare("vllmm"), in: "vllm"))
  }

  func testEmptyQueryMatchesAll() {
    XCTAssertEqual(
      FuzzyMatcher.match(FuzzyMatcher.prepare(""), in: "anything"),
      FuzzyMatch(score: 0, positions: [])
    )
  }

  func testCaseInsensitive() {
    XCTAssertNotNil(FuzzyMatcher.match(FuzzyMatcher.prepare("VLLM"), in: "vllm.pdf"))
  }

  func testConsecutiveScoresHigher() {
    let consecutive = FuzzyMatcher.match(FuzzyMatcher.prepare("abc"), in: "abc-x")!
    let scattered = FuzzyMatcher.match(FuzzyMatcher.prepare("abc"), in: "a-b-c")!
    XCTAssertGreaterThan(consecutive.score, scattered.score)
  }

  func testWordStartScoresHigher() {
    let wordStart = FuzzyMatcher.match(FuzzyMatcher.prepare("pdf"), in: "notes-pdf")!
    let midWord = FuzzyMatcher.match(FuzzyMatcher.prepare("pdf"), in: "xpdxf")!
    XCTAssertGreaterThan(wordStart.score, midWord.score)
  }

  // MARK: - 预处理查询（正规化一次、批量候选复用）

  /// 预处理结果可跨候选复用，语义与逐条查询一致（含大小写正规化）
  func testPreparedQueryReusableAcrossCandidates() {
    let prepared = FuzzyMatcher.prepare("VLLM")
    XCTAssertNotNil(FuzzyMatcher.match(prepared, in: "vllm.pdf"), "大小写正规化应在预处理阶段完成")
    XCTAssertNotNil(FuzzyMatcher.match(prepared, in: "papers/vllm-notes.md"))
    XCTAssertNil(FuzzyMatcher.match(prepared, in: "notes.md"))
  }

  /// 空查询经预处理后仍匹配一切（score 0）
  func testEmptyPreparedQueryMatchesAll() {
    XCTAssertEqual(
      FuzzyMatcher.match(FuzzyMatcher.prepare(""), in: "anything"),
      FuzzyMatch(score: 0, positions: [])
    )
  }
}
