import XCTest
@testable import MarkPDF

/// AI 助手上下文装配与轻量 markdown 分块（FR-AI.2 纯函数）
final class AIContextBuilderTests: XCTestCase {
  // MARK: - 上下文装配

  func testQuestionOnlyHasNoLabelsAndNoSummary() {
    let built = AIContextBuilder.buildUserMessage(question: "什么是注意力？", selection: nil, document: nil)
    XCTAssertEqual(built.userMessage, "什么是注意力？")
    XCTAssertNil(built.summary)
  }

  func testSelectionAndDocumentBlocks() {
    let built = AIContextBuilder.buildUserMessage(
      question: "翻译这段",
      selection: "attention is all you need",
      document: (name: "paper.pdf", text: "全文内容")
    )
    XCTAssertTrue(built.userMessage.contains("[Selection]\nattention is all you need"))
    XCTAssertTrue(built.userMessage.contains("[Document: paper.pdf]\n全文内容"))
    XCTAssertTrue(built.userMessage.hasSuffix("[Question]\n翻译这段"))
    XCTAssertEqual(built.summary, "选中文字 25 字 · 文档 paper.pdf")
  }

  func testSelectionTruncationAtBudget() {
    let long = String(repeating: "字", count: AIContextBuilder.selectionBudget + 1)
    let built = AIContextBuilder.buildUserMessage(question: "q", selection: long, document: nil)
    XCTAssertTrue(built.userMessage.contains("…(truncated)"))
    XCTAssertTrue(built.summary?.contains("截断") == true)

    let exact = String(repeating: "字", count: AIContextBuilder.selectionBudget)
    let fits = AIContextBuilder.buildUserMessage(question: "q", selection: exact, document: nil)
    XCTAssertFalse(fits.userMessage.contains("…(truncated)"))
  }

  func testDocumentTruncationAtBudget() {
    let long = String(repeating: "文", count: AIContextBuilder.documentBudget + 1)
    let built = AIContextBuilder.buildUserMessage(question: "q", selection: nil, document: (name: "a.md", text: long))
    XCTAssertTrue(built.userMessage.contains("…(truncated)"))
    XCTAssertEqual(built.summary, "文档 a.md（截断）")
  }

  func testEmptySelectionOmitted() {
    let built = AIContextBuilder.buildUserMessage(question: "q", selection: "", document: nil)
    XCTAssertEqual(built.userMessage, "q")
    XCTAssertNil(built.summary)
  }

  // MARK: - 历史裁剪

  func testTrimHistoryDropsEmptyAssistantAndCaps() {
    var history: [AIChatMessage] = []
    for index in 0..<20 {
      history.append(.user("问 \(index)"))
      history.append(.assistant(index == 5 ? "" : "答 \(index)"))
    }
    let trimmed = AIContextBuilder.trimHistory(history)
    XCTAssertEqual(trimmed.count, AIContextBuilder.historyMessageCap)
    XCTAssertFalse(trimmed.contains { $0.role == .assistant && $0.content.isEmpty })
    XCTAssertEqual(trimmed.last?.content, "答 19", "掐头留尾保最近")
  }

  // MARK: - markdown 分块

  func testPlainParagraphs() {
    XCTAssertEqual(
      MarkdownBlockSegmenter.segments("第一段\n\n第二段 **加粗**"),
      [.paragraph("第一段\n\n第二段 **加粗**")]
    )
  }

  func testCodeBlocksWithLanguage() {
    let markdown = """
      前文

      ```swift
      let a = 1
      ```

      后文
      """
    XCTAssertEqual(MarkdownBlockSegmenter.segments(markdown), [
      .paragraph("前文"),
      .code(language: "swift", code: "let a = 1"),
      .paragraph("后文"),
    ])
  }

  func testUnclosedFenceStreamsAsCode() {
    let markdown = "说明\n\n```python\nprint(1)\nprint(2)"
    XCTAssertEqual(MarkdownBlockSegmenter.segments(markdown), [
      .paragraph("说明"),
      .code(language: "python", code: "print(1)\nprint(2)"),
    ])
  }

  func testConsecutiveEmptyFence() {
    XCTAssertEqual(MarkdownBlockSegmenter.segments("```\n```"), [.code(language: nil, code: "")])
  }
}
