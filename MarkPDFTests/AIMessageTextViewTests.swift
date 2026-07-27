import XCTest
@testable import MarkPDF

/// AI 回复 markdown 行分类（标题/无序与有序列表/普通行）
final class AIMessageTextViewTests: XCTestCase {
  func testHeaderClassified() {
    XCTAssertEqual(
      AIMessageTextView.classifyLine("## 核心贡献"),
      .header(level: 2, text: "核心贡献")
    )
    XCTAssertEqual(
      AIMessageTextView.classifyLine("### 三级标题"),
      .header(level: 3, text: "三级标题")
    )
  }

  func testUnorderedBulletClassified() {
    XCTAssertEqual(
      AIMessageTextView.classifyLine("- 问题背景：KV cache 低效"),
      .bullet(indent: 0, marker: "•", text: "问题背景：KV cache 低效")
    )
    XCTAssertEqual(
      AIMessageTextView.classifyLine("* 星号也行"),
      .bullet(indent: 0, marker: "•", text: "星号也行")
    )
  }

  func testOrderedBulletKeepsNumber() {
    XCTAssertEqual(
      AIMessageTextView.classifyLine("1. DeepSeek Sparse Attention"),
      .bullet(indent: 0, marker: "1.", text: "DeepSeek Sparse Attention")
    )
    XCTAssertEqual(
      AIMessageTextView.classifyLine("12. 两位数序号"),
      .bullet(indent: 0, marker: "12.", text: "两位数序号")
    )
  }

  func testNestedIndentByTwoSpaces() {
    XCTAssertEqual(
      AIMessageTextView.classifyLine("  - 嵌套一层"),
      .bullet(indent: 1, marker: "•", text: "嵌套一层")
    )
    XCTAssertEqual(
      AIMessageTextView.classifyLine("    - 嵌套两层"),
      .bullet(indent: 2, marker: "•", text: "嵌套两层")
    )
  }

  func testPlainLinesUnaffected() {
    XCTAssertEqual(AIMessageTextView.classifyLine("普通段落文本"), .plain("普通段落文本"))
    XCTAssertEqual(AIMessageTextView.classifyLine("#井号无空格"), .plain("#井号无空格"))
    XCTAssertEqual(AIMessageTextView.classifyLine("减号-在中间"), .plain("减号-在中间"))
    XCTAssertEqual(AIMessageTextView.classifyLine("3.14 不是列表"), .plain("3.14 不是列表"))
  }
}
