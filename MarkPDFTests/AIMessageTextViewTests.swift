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

      - 列表项目一：南京老城步行路线
        - 嵌套项目：预约与开放时间

      | 项目 | 说明 |
      |---|---|
      | 交通 | 地铁、公交与步行组合 |
      | 住宿 | 新街口、夫子庙与大行宫 |

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
      .background(Color.white)
    )
    hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 900)
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
    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      let png = bitmap.representation(using: .png, properties: [:])
      let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("ai-message-layout.png")
      try? png?.write(to: snapshotURL)
      print("[AI message snapshot] \(snapshotURL.path)")
    }
  }

  /// 回归：SwiftUI 的 macOS List 底层是 NSOutlineView。协调器必须通过
  /// outlineView(_:heightOfRowByItem:) 为全部离屏行建立确定高度，否则滚动时
  /// cell 逐个物化会继续改 document height，滚动条长度和位置随之跳动。
  @MainActor
  func testTranscriptOutlineHeightMapStaysStableAcrossResizeScrollAndIdle() throws {
    let messages = makeTranscriptProbeMessages()
    let changeStore = AIChangeStore()
    let hosting = NSHostingView(rootView: TranscriptMessageListProbe(
      messages: messages,
      changeStore: changeStore
    ))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))

    let scrollView = try XCTUnwrap(findTableScrollView(in: hosting))
    let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
    XCTAssertTrue(tableView is NSOutlineView, "测试必须覆盖 SwiftUI List 的 Outline 路径")
    let coordinator = AITranscriptScrollCoordinator()
    coordinator.updateContent(messages: messages, changeStore: changeStore)
    coordinator.attach(scrollView)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    XCTAssertEqual(tableView.numberOfRows, messages.count + 1)
    XCTAssertGreaterThan(tableView.rect(ofRow: 0).height, 1)

    let anchorRow = min(15, tableView.numberOfRows - 1)
    let anchorOffset: CGFloat = 11
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: anchorRow).minY + anchorOffset))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    coordinator.beginResize()

    let widths: [CGFloat] = [280, 300, 340, 360, 340, 300, 280]
    var heights: [CGFloat] = []
    var anchors: [(Int, CGFloat)] = []
    for width in widths {
      window.setContentSize(NSSize(width: width, height: 600))
      hosting.frame.size.width = width
      hosting.layoutSubtreeIfNeeded()
      coordinator.widthDidChange()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      heights.append(tableView.bounds.height)
      let visibleY = scrollView.contentView.documentVisibleRect.minY
      let row = tableView.row(at: NSPoint(x: tableView.bounds.midX, y: visibleY + 1))
      anchors.append((row, visibleY - tableView.rect(ofRow: max(row, 0)).minY))
    }
    coordinator.endResize()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))

    XCTAssertTrue(anchors.allSatisfy { $0.0 == anchorRow && abs($0.1 - anchorOffset) <= 1 })
    XCTAssertEqual(heights[0], heights[6], accuracy: 1)
    XCTAssertEqual(heights[1], heights[5], accuracy: 1)
    XCTAssertEqual(heights[2], heights[4], accuracy: 1)
    XCTAssertGreaterThan(abs(heights[0] - heights[3]), 1, "测试正文没有随宽度改变总高度")

    let settledHeight = tableView.bounds.height
    var observedHeights: [CGFloat] = []
    for fraction in stride(from: CGFloat(0), through: 1, by: 0.1) {
      let maxY = max(tableView.bounds.height - scrollView.contentView.bounds.height, 0)
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY * fraction))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      hosting.layoutSubtreeIfNeeded()
      observedHeights.append(tableView.bounds.height)
    }
    XCTAssertTrue(observedHeights.allSatisfy { abs($0 - settledHeight) <= 1 })
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    XCTAssertEqual(tableView.bounds.height, settledHeight, accuracy: 1)
    coordinator.attach(nil)
  }

  /// 最终宽度帧尚在主队列时，第一下滚轮必须直接取消锚定；之后的异步任务
  /// 不得把用户刚产生的滚动位置写回旧锚点。
  @MainActor
  func testTranscriptFirstScrollCancelsPendingResizeAnchorWithoutLayout() throws {
    let messages = makeTranscriptProbeMessages()
    let changeStore = AIChangeStore()
    let hosting = NSHostingView(rootView: TranscriptMessageListProbe(
      messages: messages,
      changeStore: changeStore
    ))
    hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))

    let scrollView = try XCTUnwrap(findTableScrollView(in: hosting))
    let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
    let coordinator = AITranscriptScrollCoordinator()
    coordinator.updateContent(messages: messages, changeStore: changeStore)
    coordinator.attach(scrollView)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: 18).minY + 17))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    coordinator.beginResize()
    window.setContentSize(NSSize(width: 360, height: 600))
    hosting.frame.size.width = 360
    hosting.layoutSubtreeIfNeeded()
    // 模拟 mouseUp 已发布最终宽度帧、但主队列高度任务尚未执行。
    coordinator.widthDidChange()
    coordinator.endResize()

    let maximumY = max(tableView.bounds.maxY - scrollView.contentView.bounds.height, 0)
    let userTargetY = min(scrollView.contentView.bounds.minY + 90, maximumY)
    let cancelStart = CFAbsoluteTimeGetCurrent()
    coordinator.prioritizeUserScroll()
    let cancelDuration = CFAbsoluteTimeGetCurrent() - cancelStart
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: userTargetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))

    XCTAssertLessThan(cancelDuration, 0.005, "滚轮前置取消必须是 O(1): \(cancelDuration)s")
    XCTAssertEqual(scrollView.contentView.bounds.minY, userTargetY, accuracy: 1)
    coordinator.attach(nil)
  }

  @MainActor
  func testTranscriptHeightEstimatorStaysWithinFrameBudget() {
    let messages = makeTranscriptProbeMessages()
    let changeStore = AIChangeStore()
    var durations: [CFTimeInterval] = []
    for frame in 0..<60 {
      let width = CGFloat(280 + (frame % 41) * 2)
      let start = CFAbsoluteTimeGetCurrent()
      _ = messages.reduce(CGFloat.zero) {
        $0 + AIChatMessageRow.estimatedHeight(for: $1, tableWidth: width, changeStore: changeStore)
      }
      durations.append(CFAbsoluteTimeGetCurrent() - start)
    }
    let sorted = durations.sorted()
    let p95 = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
    XCTAssertLessThan(p95, 0.01, "完整会话的纯数值高度准备不得占满显示帧: \(p95)s")
  }

  @MainActor
  func testTranscriptNativeSelectableTextResizeStaysWithinFrameBudget() throws {
    let code = (1...65).map { line in
      "第 \(line) 行：南京行程、交通、住宿、门票与预约信息。"
    }.joined(separator: "\n")
    let messages = [
      AIChatStore.ChatMessage(role: .user, content: "请精简这份行程"),
      AIChatStore.ChatMessage(
        role: .assistant,
        content: "下面是精简版本：\n\n```markdown\n\(code)\n```\n\n**主要精简点：** 保留核心信息。"
      ),
    ]
    let changeStore = AIChangeStore()
    let hosting = NSHostingView(rootView: TranscriptMessageListProbe(
      messages: messages,
      changeStore: changeStore,
      allowsTextSelection: true
    ))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 900)
    let window = NSWindow(
      contentRect: hosting.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))

    let nativeText = try XCTUnwrap(findTextView(containing: "第 65 行", in: hosting))
    XCTAssertTrue(nativeText.isSelectable)
    XCTAssertFalse(nativeText.isEditable)

    var frameDurations: [CFTimeInterval] = []
    for frame in 0..<80 {
      let phase = frame % 40
      let width = phase <= 20 ? CGFloat(280 + phase * 4) : CGFloat(360 - (phase - 20) * 4)
      let start = CFAbsoluteTimeGetCurrent()
      window.setContentSize(NSSize(width: width, height: 900))
      hosting.frame.size.width = width
      hosting.layoutSubtreeIfNeeded()
      frameDurations.append(CFAbsoluteTimeGetCurrent() - start)
    }
    let sorted = frameDurations.sorted()
    let p95 = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
    XCTAssertLessThan(p95, 0.02, "原生可选择长文本拖宽 P95 超过单帧预算: \(p95)s")
  }

  @MainActor
  func testTranscriptEstimatedRowsDoNotClipRenderedContent() {
    let messages = Array(makeTranscriptProbeMessages().prefix(2))
    let changeStore = AIChangeStore()
    for tableWidth in [CGFloat(280), 320, 360] {
      let contentWidth = tableWidth - 20
      for message in messages {
        let hosting = NSHostingView(rootView: AIChatMessageRow(
          message: message,
          isBusy: false,
          changeStore: changeStore,
          allowsTextSelection: false
        ).frame(width: contentWidth))
        let renderedHeight = hosting.fittingSize.height + 14
        let estimatedHeight = AIChatMessageRow.estimatedHeight(
          for: message,
          tableWidth: tableWidth,
          changeStore: changeStore
        )
        XCTAssertGreaterThanOrEqual(
          estimatedHeight + 1,
          renderedHeight,
          "估算行高不足会裁掉内容，width=\(tableWidth), role=\(message.role)"
        )
      }
    }
  }

  private func makeTranscriptProbeMessages() -> [AIChatStore.ChatMessage] {
    (0..<29).map { index in
      if index.isMultiple(of: 4) {
        var message = AIChatStore.ChatMessage(
          role: .user,
          content: "请根据前面的内容重新整理第 \(index + 1) 部分，并保持关键信息完整。"
        )
        message.contextSummary = "当前文档 · 选区 320 字"
        return message
      }
      return AIChatStore.ChatMessage(
        role: .assistant,
        content: transcriptProbeMarkdown + "\n\n补充说明 \(index + 1)：请提前核对开放时间、交通方式与预约要求。"
      )
    }
  }

  @MainActor
  private func findTableScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView,
       scrollView.documentView is NSTableView
    {
      return scrollView
    }
    for child in view.subviews {
      if let found = findTableScrollView(in: child) { return found }
    }
    return nil
  }

  @MainActor
  private func findTextView(containing text: String, in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView, textView.string.contains(text) { return textView }
    for child in view.subviews {
      if let found = findTextView(containing: text, in: child) { return found }
    }
    return nil
  }
}

private let transcriptProbeMarkdown = """
    ## 行程建议

    这是一段会在侧栏宽度变化时产生多行换行的长文本，用来模拟真实 AI 历史回复的动态高度。

    - 第一项包含较长的说明文字和交通、预约、开放时间等信息。
    - 第二项同样包含足够多的文字，以便不同宽度产生明显不同的行高。
    - 第三项继续补充预算、住宿、餐饮与注意事项。

    | 项目 | 说明 |
    |---|---|
    | 交通 | 地铁、公交与步行组合 |
    | 住宿 | 新街口、夫子庙与大行宫 |
    """

private struct TranscriptMessageListProbe: View {
  let messages: [AIChatStore.ChatMessage]
  let changeStore: AIChangeStore
  var allowsTextSelection = false

  var body: some View {
    List {
      ForEach(messages) { message in
        AIChatMessageRow(
          message: message,
          isBusy: false,
          changeStore: changeStore,
          allowsTextSelection: allowsTextSelection
        )
        .listRowInsets(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
        .listRowSeparator(.hidden)
      }
      Color.clear
        .frame(height: 1)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 1)
  }
}
