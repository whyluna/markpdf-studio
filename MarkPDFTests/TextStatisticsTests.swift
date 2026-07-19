import XCTest
@testable import MarkPDF

/// 文本统计（FR-2.8）：字数口径、字符数、阅读时长
final class TextStatisticsTests: XCTestCase {
  func testChineseCharactersCountIndividually() {
    let stats = TextStatistics.of("知识管理")
    XCTAssertEqual(stats.words, 4)
    XCTAssertEqual(stats.characters, 4)
  }

  func testLatinWordsCountPerWord() {
    let stats = TextStatistics.of("hello world foo")
    XCTAssertEqual(stats.words, 3)
    XCTAssertEqual(stats.characters, 13)
  }

  func testMixedChineseAndLatin() {
    let stats = TextStatistics.of("使用 KV Cache 加速推理")
    // 使用(2) KV(1) Cache(1) 加速推理(4) = 8
    XCTAssertEqual(stats.words, 8)
  }

  func testCJKPunctuationCountsAsWord() {
    let stats = TextStatistics.of("你好，世界。")
    XCTAssertEqual(stats.words, 6)
  }

  func testWhitespaceAndNewlinesExcluded() {
    let stats = TextStatistics.of("a b\nc\td\n\n")
    XCTAssertEqual(stats.characters, 4)
    XCTAssertEqual(stats.words, 4)
  }

  func testEmptyText() {
    let stats = TextStatistics.of("")
    XCTAssertEqual(stats, EditorStats(words: 0, characters: 0, readingMinutes: 0))
  }

  func testReadingMinutes() {
    XCTAssertEqual(TextStatistics.of(String(repeating: "字", count: 1)).readingMinutes, 1)
    XCTAssertEqual(TextStatistics.of(String(repeating: "字", count: 400)).readingMinutes, 1)
    XCTAssertEqual(TextStatistics.of(String(repeating: "字", count: 401)).readingMinutes, 2)
    XCTAssertEqual(TextStatistics.of(String(repeating: "字", count: 1200)).readingMinutes, 3)
  }
}
