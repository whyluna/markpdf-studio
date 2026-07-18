import XCTest
@testable import MarkPDF

/// FR-6.1 模糊匹配单测
final class FuzzyMatcherTests: XCTestCase {
  func testSubsequenceMatch() {
    XCTAssertNotNil(FuzzyMatcher.match(query: "vllm", in: "vllm.pdf"))
    XCTAssertNotNil(FuzzyMatcher.match(query: "vp", in: "vllm.pdf"))
    XCTAssertNotNil(FuzzyMatcher.match(query: "组汇", in: "组会汇报.md"))
  }

  func testNonMatch() {
    XCTAssertNil(FuzzyMatcher.match(query: "xyz", in: "vllm.pdf"))
    XCTAssertNil(FuzzyMatcher.match(query: "vllmm", in: "vllm"))
  }

  func testEmptyQueryMatchesAll() {
    XCTAssertEqual(FuzzyMatcher.match(query: "", in: "anything"), FuzzyMatch(score: 0, positions: []))
  }

  func testCaseInsensitive() {
    XCTAssertNotNil(FuzzyMatcher.match(query: "VLLM", in: "vllm.pdf"))
  }

  func testConsecutiveScoresHigher() {
    let consecutive = FuzzyMatcher.match(query: "abc", in: "abc-x")!
    let scattered = FuzzyMatcher.match(query: "abc", in: "a-b-c")!
    XCTAssertGreaterThan(consecutive.score, scattered.score)
  }

  func testWordStartScoresHigher() {
    let wordStart = FuzzyMatcher.match(query: "pdf", in: "notes-pdf")!
    let midWord = FuzzyMatcher.match(query: "pdf", in: "xpdxf")!
    XCTAssertGreaterThan(wordStart.score, midWord.score)
  }
}
