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

  func testDocumentBudgetParameterOverridesDefault() {
    let text = String(repeating: "文", count: 10_000)
    // 传大预算不截断（默认 8000 会截）
    let big = AIContextBuilder.buildUserMessage(
      question: "q", selection: nil, document: (name: "a.md", text: text), documentBudget: 20_000
    )
    XCTAssertFalse(big.userMessage.contains("…(truncated)"))
    let small = AIContextBuilder.buildUserMessage(
      question: "q", selection: nil, document: (name: "a.md", text: text), documentBudget: 5_000
    )
    XCTAssertTrue(small.userMessage.contains("…(truncated)"))
  }

  // MARK: - 上下文预算（v1.3：窗口/回复上限均为用户设定）

  func testSuggestedTokensForPrefill() {
    XCTAssertEqual(AIModelContext.suggestedTokens(forModel: "moonshot-v1-8k"), 8_000)
    XCTAssertEqual(AIModelContext.suggestedTokens(forModel: "claude-3-5-sonnet-latest"), 200_000)
    XCTAssertEqual(AIModelContext.suggestedTokens(forModel: "gemini-2.0-flash"), 1_000_000)
    XCTAssertEqual(AIModelContext.suggestedTokens(forModel: "deepseek-chat"), 64_000)
    XCTAssertEqual(AIModelContext.suggestedTokens(forModel: "some-unknown-model"), AIModelContext.conservativeTokens)
  }

  func testEffectiveReplyTokensClampsToHalfWindow() {
    // 正常：用户值直用
    XCTAssertEqual(AIModelContext.effectiveReplyTokens(userSetting: 8192, contextTokens: 64_000), 8192)
    // 用户设定 ≥ 窗口（输入输出共享，回复占满则无输入空间）→ 夹到窗口一半
    XCTAssertEqual(AIModelContext.effectiveReplyTokens(userSetting: 10_000, contextTokens: 8_000), 4_000)
    // 非法 0 → 窗口一半
    XCTAssertEqual(AIModelContext.effectiveReplyTokens(userSetting: 0, contextTokens: 8_000), 4_000)
  }

  func testDocumentCharBudgetMatrix() {
    // 8k 窗口 + 回复 8192（被夹到 4000）：8000-4000-2000-5000 < 0 → 下限 2000
    XCTAssertEqual(AIModelContext.documentCharBudget(contextTokens: 8_000, replyTokens: 8192), AIModelContext.minDocumentChars)
    // 64k 窗口 + 回复 8192：64000-8192-16000-5000 = 34808
    XCTAssertEqual(AIModelContext.documentCharBudget(contextTokens: 64_000, replyTokens: 8192), 34_808)
    // 1M 窗口：夹到上限
    XCTAssertEqual(AIModelContext.documentCharBudget(contextTokens: 1_000_000, replyTokens: 8192), AIModelContext.maxDocumentChars)
  }

  func testHistoryCharBudget() {
    // 窗口 25%：64k → 16000；200k → 50000（<60k 封顶）；1M → 封顶 60000
    XCTAssertEqual(AIModelContext.historyCharBudget(contextTokens: 64_000), 16_000)
    XCTAssertEqual(AIModelContext.historyCharBudget(contextTokens: 200_000), 50_000)
    XCTAssertEqual(AIModelContext.historyCharBudget(contextTokens: 1_000_000), AIModelContext.maxHistoryChars)
  }

  func testPreserveRecentCharsIs70PercentOfHistoryBudget() {
    // 64k 窗口：历史 16000 → 保留区 11200
    XCTAssertEqual(AIModelContext.preserveRecentChars(contextTokens: 64_000), 11_200)
  }

  // MARK: - 保留区分割（v1.4）

  func testSplitForPreservationAllFitsCompactsNothing() {
    let history: [AIChatMessage] = [.user("问1"), .assistant("答1"), .user("问2"), .assistant("答2")]
    let split = AIContextBuilder.splitForPreservation(history, preserveChars: 1_000)
    XCTAssertTrue(split.toCompact.isEmpty)
    XCTAssertEqual(split.preserved.count, 4)
  }

  func testSplitForPreservationAlignsToTurnBoundary() {
    let history: [AIChatMessage] = [
      .user(String(repeating: "一", count: 10)),
      .assistant(String(repeating: "答", count: 10)),
      .user(String(repeating: "二", count: 10)),
      .assistant(String(repeating: "复", count: 10)),
    ]
    // 预算 25：尾部 user+assistant（20 字）装得下，再往前会劈开第一轮 → 分割点落轮次边界
    let split = AIContextBuilder.splitForPreservation(history, preserveChars: 25)
    XCTAssertEqual(split.toCompact.count, 2, "第一轮整体滚出")
    XCTAssertEqual(split.preserved.first?.role, .user, "preserved 首条必须是 user（不劈轮）")
    XCTAssertEqual(split.preserved.count, 2)
  }

  func testSplitForPreservationOverlongLastTurnStillPreserved() {
    let history: [AIChatMessage] = [
      .user("旧问"), .assistant("旧答"),
      .user("新问"), .assistant(String(repeating: "超", count: 500)),
    ]
    // 最后一轮已超预算 → 保底保留最后一轮完整原文，其余滚出
    let split = AIContextBuilder.splitForPreservation(history, preserveChars: 100)
    XCTAssertEqual(split.toCompact.map(\.content), ["旧问", "旧答"])
    XCTAssertEqual(split.preserved.first?.content, "新问")
  }

  func testCompactionMaxTokensProportionalWithClamp() {
    // 小输入夹到下限 512；2 万字 → 3000；超大夹到上限 4096
    XCTAssertEqual(AIContextBuilder.compactionMaxTokens(forInputChars: 3_000), 512)
    XCTAssertEqual(AIContextBuilder.compactionMaxTokens(forInputChars: 20_000), 3_000)
    XCTAssertEqual(AIContextBuilder.compactionMaxTokens(forInputChars: 100_000), 4_096)
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

  // MARK: - 历史分层（v1.3）

  func testHistoryMessagesInjectsRollingSummaryWithPairedPlaceholder() {
    let history: [AIChatMessage] = [.user("旧问"), .assistant("旧答")]
    let out = AIContextBuilder.historyMessages(history, rollingSummary: "早期结论：X 有效", charBudget: 10_000)
    XCTAssertEqual(out.count, 4)
    XCTAssertTrue(out[0].content.hasPrefix("[Earlier conversation summary]"))
    XCTAssertEqual(out[1].role, .assistant, "配对占位保交替")
    XCTAssertEqual(out[2].content, "旧问")
  }

  func testHistoryMessagesCharBudgetTrimsOldestFirst() {
    let history: [AIChatMessage] = [
      .user(String(repeating: "旧", count: 500)),
      .assistant(String(repeating: "答", count: 500)),
      .user("新问"),
      .assistant("新答"),
    ]
    let out = AIContextBuilder.historyMessages(history, rollingSummary: nil, charBudget: 100)
    XCTAssertEqual(out.map(\.content).last, "新答")
    XCTAssertTrue(out.count < 4, "超字符预算从旧端掐头")
    XCTAssertEqual(out.first?.content, "新问", "保最新")
  }

  func testHistoryMessagesClipsOverlongSummaryTo30Percent() {
    let long = String(repeating: "摘", count: 500)
    let out = AIContextBuilder.historyMessages([.user("问"), .assistant("答")], rollingSummary: long, charBudget: 1_000)
    // 注入区上限 = 1000 × 30% = 300 字 + 截断标记
    let injected = out[0].content
    XCTAssertTrue(injected.contains("…(truncated)"))
    XCTAssertTrue(injected.contains(String(repeating: "摘", count: 300)))
    XCTAssertFalse(injected.contains(String(repeating: "摘", count: 301)))
  }

  func testCompactionMessagesShape() {
    let out = AIContextBuilder.compactionMessages(
      existingSummary: "旧摘要",
      turns: [.user("问"), .assistant("答 [§3.2]")]
    )
    XCTAssertEqual(out.count, 2)
    XCTAssertEqual(out[0].role, .system)
    XCTAssertTrue(out[1].content.contains("Previous summary:\n旧摘要"))
    XCTAssertTrue(out[1].content.contains("assistant: 答 [§3.2]"))
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
