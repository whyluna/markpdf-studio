import SwiftMath
import SwiftUI
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

  // MARK: - 评审补边（Tab 缩进 / 前导空格标题 / 空标题守卫）

  func testTabIndentCountsOneLevel() {
    XCTAssertEqual(
      AIMessageTextView.classifyLine("\t- 嵌套项"),
      .bullet(indent: 1, marker: "•", text: "嵌套项")
    )
  }

  func testLeadingSpaceHeaderAllowed() {
    XCTAssertEqual(
      AIMessageTextView.classifyLine("  ## 前导空格标题"),
      .header(level: 2, text: "前导空格标题")
    )
  }

  func testEmptyHeaderFallsBackToPlain() {
    XCTAssertEqual(AIMessageTextView.classifyLine("# "), .plain("# "))
  }

  // MARK: - 分割线

  func testHorizontalRuleClassified() {
    XCTAssertEqual(AIMessageTextView.classifyLine("---"), .rule)
    XCTAssertEqual(AIMessageTextView.classifyLine("***"), .rule)
    XCTAssertEqual(AIMessageTextView.classifyLine("___"), .rule)
    XCTAssertEqual(AIMessageTextView.classifyLine("- - -"), .rule, "带空格的分割线也是分割线")
    XCTAssertEqual(AIMessageTextView.classifyLine("--"), .plain("--"), "两连字符不是分割线")
  }

  // MARK: - 引用块

  func testBlockquoteClassified() {
    XCTAssertEqual(
      AIMessageTextView.classifyLine("> 这是一段引用文本。"),
      .quote(depth: 1, text: "这是一段引用文本。")
    )
    XCTAssertEqual(AIMessageTextView.classifyLine(">"), .quote(depth: 1, text: ""), "空引用行")
    XCTAssertEqual(
      AIMessageTextView.classifyLine(">> 这是嵌套引用。"),
      .quote(depth: 2, text: "这是嵌套引用。")
    )
    XCTAssertEqual(
      AIMessageTextView.classifyLine("> > 带空格的嵌套"),
      .quote(depth: 2, text: "带空格的嵌套")
    )
    XCTAssertEqual(AIMessageTextView.classifyLine("普通 > 不是引用"), .plain("普通 > 不是引用"))
  }

  // MARK: - 段落分块（表格 / 块级公式）

  func testTableBlockParsed() {
    let blocks = AIMessageTextView.parseBlocks("| 领域 | 结论 |\n|---|---|\n| 推理 | 与 GPT-5 相当 |\n| 代码 | **大幅超越** |")
    XCTAssertEqual(
      blocks,
      [.table([["领域", "结论"], ["推理", "与 GPT-5 相当"], ["代码", "**大幅超越**"]])]
    )
  }

  func testTableRequiresSeparator() {
    let blocks = AIMessageTextView.parseBlocks("| a | b |\n| c | d |")
    XCTAssertEqual(blocks, [.line("| a | b |"), .line("| c | d |")], "无 |---| 分隔行不判为表格")
  }

  func testTableCellsTrimmedAndRaggedFilled() {
    XCTAssertEqual(
      AIMessageTextView.splitTableCells("| a | b |"),
      ["a", "b"]
    )
  }

  func testMathBlockParsed() {
    let blocks = AIMessageTextView.parseBlocks("前文\n$$\n\\mathcal{J}(\\theta)\n$$\n后文")
    XCTAssertEqual(blocks, [.line("前文"), .math("\\mathcal{J}(\\theta)"), .line("后文")])
  }

  func testMathBlockUnclosedSwallowsRest() {
    let blocks = AIMessageTextView.parseBlocks("$$\nx^2\ny^2")
    XCTAssertEqual(blocks, [.math("x^2\ny^2")], "未闭合公式块收编到段尾（流式安全）")
  }

  func testSingleLineDisplayMathParsed() {
    XCTAssertEqual(
      AIMessageTextView.parseBlocks("$$\\mathcal{J}(\\theta) = \\mathbb{E}[x]$$"),
      [.math("\\mathcal{J}(\\theta) = \\mathbb{E}[x]")],
      "单行 $$...$$ 也是块级公式（模型常写成一行）"
    )
    // 前后都有普通文本时不按块级（走行内混排路径）
    let mixed = AIMessageTextView.parseBlocks("结果 $$x^2$$ 如上")
    XCTAssertEqual(mixed, [.line("结果 $$x^2$$ 如上")])
  }

  // MARK: - 行内公式

  func testInlineMathDetected() {
    XCTAssertTrue(AIMessageTextView.containsInlineMath("行内公式 $E = mc^2$ 结束"))
    XCTAssertFalse(AIMessageTextView.containsInlineMath("只有一个 $ 符号"))
    XCTAssertFalse(AIMessageTextView.containsInlineMath("普通文本"))
    XCTAssertFalse(AIMessageTextView.containsInlineMath("转义 \\$100 和 \\$200"))
  }

  // MARK: - SwiftMath 原生排版（替换 WKWebView/KaTeX）

  @MainActor
  func testSplitInlineMath() {
    XCTAssertEqual(
      SwiftMathRenderer.splitInlineMath("行内 $E=mc^2$ 结束"),
      [.text("行内 "), .math("E=mc^2"), .text(" 结束")]
    )
    XCTAssertEqual(
      SwiftMathRenderer.splitInlineMath("两段 $a$ 和 $b$"),
      [.text("两段 "), .math("a"), .text(" 和 "), .math("b")]
    )
    XCTAssertEqual(
      SwiftMathRenderer.splitInlineMath("未闭合 $x^2"),
      [.text("未闭合 $x^2")],
      "奇数个 $ 时尾段按普通文本回落"
    )
    XCTAssertEqual(
      SwiftMathRenderer.splitInlineMath("普通文本"),
      [.text("普通文本")]
    )
  }

  /// 同步量取：无 JS 无异步，尺寸即所得（滚动稳定的关键）
  @MainActor
  func testSwiftMathMeasuresSynchronously() {
    let size = SwiftMathRenderer.measure(latex: "E = mc^2", fontSize: 15, displayMode: true)
    XCTAssertGreaterThan(size.width, 10, "块级公式应有排版宽度")
    XCTAssertGreaterThan(size.height, 5)
    let inline = SwiftMathRenderer.measure(latex: "x_i", fontSize: 14, displayMode: false)
    XCTAssertGreaterThan(inline.width, 5)
  }

  /// 行内位图渲染 + 渲染质量自证（写 PNG 供离屏检查）
  @MainActor
  func testSwiftMathRendersImage() throws {
    let result = SwiftMathRenderer.image(latex: "\\frac{1}{G}\\sum_{i=1}^{G} r_i", fontSize: 14)
    XCTAssertNotNil(result)
    XCTAssertGreaterThan(result?.size.width ?? 0, 20)
    // 长行内公式：自然宽度量取（不换行），位图必须完整无裁剪
    let longResult = SwiftMathRenderer.image(
      latex: "I_{t,s} = \\sum_{j=1}^{H_l} w^I_{t,j} \\cdot \\text{ReLU}(q^I_{t,j} \\cdot k^I_s)",
      fontSize: 14
    )
    XCTAssertNotNil(longResult)
    // 实测自然单行 177.5×42.5（含求和上下限的超高盒——超高公式由视图层改走块级展示）
    XCTAssertGreaterThan(longResult?.size.width ?? 0, 100)
    XCTAssertGreaterThan(longResult?.size.height ?? 0, 14 * 2)
    for (name, image) in [("swiftmath-render", result?.image), ("swiftmath-inline-long", longResult?.image)] {
      if let image,
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
      {
        // 沙盒内可写目录；PNG 供离屏渲染质量检查
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"))
      }
    }
  }

  /// 布局巡检（滚动幽灵高度定位）：混合内容列里不应有远超内容的保留高度
  @MainActor
  func testLayoutHasNoPhantomHeight() {
    let markdown = """
      ## 数学公式（如支持）

      行内公式：$E = mc^2$，注意力分数 $I_{t,s} = \\sum_{j=1}^{H_l} w^I_{t,j} \\cdot \\text{ReLU}(q^I_{t,j} \\cdot k^I_s)$

      块级公式：

      $$
      o_i = \\sum_{j=1}^{[i/B]} V_j A^T_{ij}
      $$

      ---

      测试结束 — 由 MarkPDF Studio 生成 ✨✨

      如需调整内容（比如换公式、改表格、增加脚注/目录等），随时告诉我！
      """
    let hosting = NSHostingView(rootView:
      ScrollView {
        AIMessageTextView(markdown: markdown)
          .padding(10)
          .frame(width: 360)
      }
      .frame(width: 380, height: 900)
    )
    hosting.layoutSubtreeIfNeeded()
    var tall: [(String, CGFloat)] = []
    func walk(_ view: NSView, depth: Int) {
      if view.frame.height > 60, depth > 1 {
        tall.append((String(describing: type(of: view)), view.frame.height))
      }
      view.subviews.forEach { walk($0, depth: depth + 1) }
    }
    walk(hosting, depth: 0)
    for (type, height) in tall {
      print("[布局巡检] \(type): h=\(height)")
    }
    // 列出疑似幽灵：除 ScrollView/ClipView 外，单个子视图高度异常（>200 且非文本容器）
    let suspects = tall.filter { $0.1 > 200 && !$0.0.contains("Scroll") && !$0.0.contains("Clip") && !$0.0.contains("Text") }
    XCTAssertTrue(suspects.isEmpty, "发现疑似幽灵高度视图: \(suspects)")
  }
}
