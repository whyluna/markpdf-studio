import AppKit
import SwiftUI

/// AI 回复的轻量 markdown 渲染（FR-AI.2）：围栏代码块自绘（等宽+底色+复制），
/// 段落按行解析块级结构——标题/无序与有序列表/分割线/管道表格/$$ 块级公式
/// （AttributedString 的 inlineOnly 模式不处理块级结构），行内样式仍走
/// AttributedString(markdown:)；失败回退纯文本。
/// Equatable + 调用侧 .equatable()：内容不变的历史消息跳过整段重新解析排版——
/// 会话里任何状态发布（如变更卡应用/撤销）都会重求整个转录 body，
/// 不跳过时每条消息的逐行解析累加成「文档已变、按钮迟迟不切」的可感延迟
struct AIMessageTextView: View, Equatable {
  let markdown: String
  var allowsTextSelection = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownBlockSegmenter.segments(markdown).enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .paragraph(let text):
          paragraphView(text)
        case .code(let language, let code):
          AICodeBlockView(
            language: language,
            code: code,
            allowsTextSelection: allowsTextSelection
          )
        }
      }
    }
  }

  // MARK: - 段落（按行解析块级结构）

  enum LineKind: Equatable {
    case header(level: Int, text: String)
    case bullet(indent: Int, marker: String, text: String)
    case quote(depth: Int, text: String)
    case rule
    case plain(String)
  }

  /// 行分类：# 标题（允许前导空格，空 # 行守卫）/ 无序列表（- * +）/
  /// 有序列表（1.）/ 引用块（> 每层一级）/ 分割线（--- *** ___）/ 普通行；
  /// 缩进每 2 空格一级，Tab 计一级
  static func classifyLine(_ line: String) -> LineKind {
    let leadingSpaces = line.prefix(while: { $0 == " " }).count
    var content = String(line.dropFirst(leadingSpaces))
    var hashes = 0
    var rest = Substring(content)
    while rest.first == "#" {
      hashes += 1
      rest = rest.dropFirst()
    }
    if (1...6).contains(hashes), rest.first == " ", !rest.dropFirst().isEmpty {
      return .header(level: hashes, text: String(rest.dropFirst()))
    }
    // 引用：每个 > 一层深度（后可有可无一格空格）；">" 单独成行是空引用行
    var quoteDepth = 0
    var quoteRest = Substring(content)
    while quoteRest.first == ">" {
      quoteDepth += 1
      quoteRest = quoteRest.dropFirst()
      if quoteRest.first == " " { quoteRest = quoteRest.dropFirst() }
    }
    if quoteDepth > 0 { return .quote(depth: quoteDepth, text: String(quoteRest)) }
    // 分割线：整行（可含空格）由 3+ 个 - * _ 组成；先于列表判定（'- - -' 不是列表项）
    let squashed = content.replacingOccurrences(of: " ", with: "")
    if squashed.count >= 3,
      squashed.allSatisfy({ $0 == "-" }) || squashed.allSatisfy({ $0 == "*" }) || squashed.allSatisfy({ $0 == "_" })
    {
      return .rule
    }
    var indent = leadingSpaces / 2
    if content.hasPrefix("\t") {
      indent += 1
      content = String(content.dropFirst())
    }
    if let marker = content.first, ["-", "*", "+"].contains(marker), content.dropFirst().first == " " {
      return .bullet(indent: indent, marker: "•", text: String(content.dropFirst(2)))
    }
    let digits = content.prefix(while: { $0.isNumber })
    if !digits.isEmpty, content.dropFirst(digits.count).hasPrefix(". ") {
      return .bullet(
        indent: indent,
        marker: "\(digits).",
        text: String(content.dropFirst(digits.count + 2))
      )
    }
    return .plain(line)
  }

  /// 段落内的块：行 / 表格（含表头行）/ 块级公式（LaTeX 源）
  enum Block: Equatable {
    case line(String)
    case table([[String]])
    case math(String)
  }

  /// 段落分块：$$ 块级公式、| 管道表格（表头 + |---| 分隔 + 数据行）、其余逐行
  static func parseBlocks(_ text: String) -> [Block] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [Block] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "$$" {
        var math: [String] = []
        index += 1
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "$$" {
          math.append(lines[index])
          index += 1
        }
        index += 1  // 跳过收尾 $$
        blocks.append(.math(math.joined(separator: "\n")))
        continue
      }
      // 单行块级公式：$$...$$ 整行（模型常写成一行，此前落到行内被按 $ 切碎）
      if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
        let inner = String(trimmed.dropFirst(2).dropLast(2))
        if !inner.trimmingCharacters(in: .whitespaces).isEmpty {
          blocks.append(.math(inner))
          index += 1
          continue
        }
      }
      if isTableRow(trimmed), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
        var rows = [splitTableCells(line)]
        index += 2
        while index < lines.count, isTableRow(lines[index].trimmingCharacters(in: .whitespaces)) {
          rows.append(splitTableCells(lines[index]))
          index += 1
        }
        blocks.append(.table(rows))
        continue
      }
      blocks.append(.line(line))
      index += 1
    }
    return blocks
  }

  static func isTableRow(_ trimmed: String) -> Bool {
    trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2
  }

  static func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard isTableRow(trimmed) else { return false }
    let cells = splitTableCells(trimmed)
    return !cells.isEmpty && cells.allSatisfy { cell in
      let squashed = cell.replacingOccurrences(of: " ", with: "")
      return !squashed.isEmpty && squashed.contains("-")
        && squashed.allSatisfy { $0 == "-" || $0 == ":" }
    }
  }

  static func splitTableCells(_ line: String) -> [String] {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") { trimmed.removeFirst() }
    if trimmed.hasSuffix("|") { trimmed.removeLast() }
    return trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  private func paragraphView(_ text: String) -> some View {
    let blocks = renderBlocks(Self.parseBlocks(text))
    return VStack(alignment: .leading, spacing: 3) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        renderBlockView(block)
      }
    }
  }

  /// 渲染层把连续普通行合成一个 Text。此前每一行都是独立 Text/HStack，
  /// 两三条可见长回复在宽度变化时就要布局数十个 SwiftUI 节点；合并后由
  /// TextKit 一次完成换行。表格、公式、分割线与需块级公式的行仍独立渲染。
  private enum RenderBlock {
    case lines([String])
    case richLine(String)
    case table([[String]])
    case math(String)
    case rule
  }

  private func renderBlocks(_ blocks: [Block]) -> [RenderBlock] {
    var result: [RenderBlock] = []
    var lines: [String] = []
    func flushLines() {
      guard !lines.isEmpty else { return }
      result.append(.lines(lines))
      lines.removeAll(keepingCapacity: true)
    }

    for block in blocks {
      switch block {
      case .line(let line):
        switch Self.classifyLine(line) {
        case .rule:
          flushLines()
          result.append(.rule)
        default:
          if Self.containsInlineMath(line) {
            flushLines()
            result.append(.richLine(line))
          } else {
            lines.append(line)
          }
        }
      case .table(let rows):
        flushLines()
        result.append(.table(rows))
      case .math(let source):
        flushLines()
        result.append(.math(source))
      }
    }
    flushLines()
    return result
  }

  @ViewBuilder
  private func renderBlockView(_ block: RenderBlock) -> some View {
    switch block {
    case .lines(let lines):
      combinedLinesView(lines)
    case .richLine(let line):
      lineView(line)
    case .table(let rows):
      tableView(rows)
    case .math(let source):
      mathView(source)
    case .rule:
      Rectangle()
        .fill(Color.primary.opacity(0.3))
        .frame(height: 1)
        .padding(.vertical, 3)
    }
  }

  private func combinedLinesView(_ lines: [String]) -> some View {
    AIAttributedTextView(
      text: nativeCombinedLines(lines),
      isSelectable: allowsTextSelection
    )
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// SwiftUI Text 的 SelectionOverlay 在长回复恢复时会阻塞主线程。普通 Markdown
  /// 行已经合并为单一富文本，直接交给 TextKit 可保留连续选择并原地切换
  /// `isSelectable`，无需创建/销毁选择覆盖层。
  private func nativeCombinedLines(_ lines: [String]) -> NSAttributedString {
    let value = NSMutableAttributedString(combinedLines(lines))
    let fullRange = NSRange(location: 0, length: value.length)
    guard fullRange.length > 0 else { return value }
    fillMissingAttribute(
      .font,
      value: NSFont.systemFont(ofSize: 14),
      in: value,
      range: fullRange
    )
    fillMissingAttribute(
      .foregroundColor,
      value: NSColor.labelColor,
      in: value,
      range: fullRange
    )

    let inlineIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")
    value.enumerateAttribute(inlineIntentKey, in: fullRange) { intent, range, _ in
      guard let rawValue = (intent as? NSNumber)?.intValue else { return }
      var font = (value.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        ?? NSFont.systemFont(ofSize: 14)
      if rawValue & 4 != 0 {
        font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        value.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
      } else {
        var traits: NSFontTraitMask = []
        if rawValue & 1 != 0 { traits.insert(.italicFontMask) }
        if rawValue & 2 != 0 { traits.insert(.boldFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
      }
      value.addAttribute(.font, value: font, range: range)
      if rawValue & 8 != 0 {
        value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
      }
    }
    return value
  }

  private func fillMissingAttribute(
    _ key: NSAttributedString.Key,
    value: Any,
    in string: NSMutableAttributedString,
    range: NSRange
  ) {
    var missing: [NSRange] = []
    string.enumerateAttribute(key, in: range) { attribute, subrange, _ in
      if attribute == nil { missing.append(subrange) }
    }
    for subrange in missing { string.addAttribute(key, value: value, range: subrange) }
  }

  @ViewBuilder
  private func selectable<Content: View>(_ content: Content) -> some View {
    if allowsTextSelection {
      content.textSelection(.enabled)
    } else {
      content
    }
  }

  /// 连续 Markdown 行的单一富文本。段落样式保留列表的悬挂缩进、引用层级，
  /// 行内 markdown 属性继续来自 `inlineRendered`。
  private func combinedLines(_ lines: [String]) -> AttributedString {
    var result = AttributedString()
    for (index, line) in lines.enumerated() {
      if index > 0 { result.append(AttributedString("\n")) }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = 3
      var rendered: AttributedString
      switch Self.classifyLine(line) {
      case .header(let level, let text):
        rendered = inlineRendered(text)
        rendered = applyingAppKitAttributes(
          [.font: NSFont.systemFont(ofSize: level <= 2 ? 15 : 14, weight: .semibold)],
          to: rendered
        )
      case .bullet(let indent, let marker, let text):
        // SwiftUI Text 在部分 macOS 版本不会绘制 NSParagraphStyle 的
        // firstLineHeadIndent；显式 em 空格保证嵌套层级视觉上仍成立。
        var prefix = AttributedString(String(repeating: "\u{2003}", count: indent) + "\(marker) ")
        prefix.foregroundColor = NSColor.secondaryLabelColor
        rendered = prefix
        rendered.append(inlineRendered(text))
        let baseIndent = CGFloat(indent) * 12
        paragraph.firstLineHeadIndent = baseIndent
        paragraph.headIndent = baseIndent + max(14, ceil((marker as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width + 5))
      case .quote(let depth, let text):
        let baseIndent = CGFloat(depth - 1) * 12
        var prefix = AttributedString(String(repeating: "\u{2003}", count: depth - 1) + "▎ ")
        prefix.foregroundColor = NSColor.tertiaryLabelColor
        rendered = prefix
        var quote = inlineRendered(text)
        quote.foregroundColor = NSColor.secondaryLabelColor
        rendered.append(quote)
        paragraph.firstLineHeadIndent = baseIndent
        paragraph.headIndent = baseIndent + 12
      case .plain(let text):
        rendered = inlineRendered(text)
      case .rule:
        continue
      }
      rendered = applyingAppKitAttributes([.paragraphStyle: paragraph], to: rendered)
      result.append(rendered)
    }
    return result
  }

  /// 通过 NSAttributedString 桥接 AppKit 段落属性，避免把不可 Sendable 的
  /// NSFont/NSParagraphStyle 直接写进 Swift AttributedString 属性作用域。
  private func applyingAppKitAttributes(
    _ attributes: [NSAttributedString.Key: Any],
    to value: AttributedString
  ) -> AttributedString {
    let mutable = NSMutableAttributedString(value)
    guard mutable.length > 0 else { return value }
    mutable.addAttributes(attributes, range: NSRange(location: 0, length: mutable.length))
    return AttributedString(mutable)
  }

  /// 管道表格：表头加粗 + 分隔线 + 数据行（列数不齐补空）
  private func tableView(_ rows: [[String]]) -> some View {
    let columnCount = rows.map(\.count).max() ?? 0
    return VStack(alignment: .leading, spacing: 4) {
      if let header = rows.first {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
          ForEach(0..<columnCount, id: \.self) { column in
            Text(inlineRendered(header.indices.contains(column) ? header[column] : ""))
              .font(.system(size: 14, weight: .semibold))
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        // 表头分隔线：显式矩形（Divider 在此环境几乎不可见）
        Rectangle()
          .fill(Color.primary.opacity(0.3))
          .frame(height: 1)
      }
      ForEach(Array(rows.indices.dropFirst()), id: \.self) { rowIndex in
        HStack(alignment: .firstTextBaseline, spacing: 14) {
          ForEach(0..<columnCount, id: \.self) { column in
            Text(inlineRendered(rows[rowIndex].indices.contains(column) ? rows[rowIndex][column] : ""))
              .font(.system(size: 14))
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .padding(.vertical, 2)
  }

  /// 块级公式：SwiftMath 原生排版（CoreText 同步布局，替换 WKWebView/KaTeX）
  private func mathView(_ source: String) -> some View {
    SwiftMathBlockView(source: source)
  }

  /// 含非转义 $ 成对出现（$$ 已先行成块）：该行需 KaTeX 行内混排
  static func containsInlineMath(_ text: String) -> Bool {
    var count = 0
    var previous: Character = " "
    for char in text {
      if char == "$", previous != "\\" { count += 1 }
      previous = char
    }
    return count >= 2
  }

  @ViewBuilder
  private func lineView(_ line: String) -> some View {
    switch Self.classifyLine(line) {
    case .header(let level, let text):
      selectable(
        Text(inlineRendered(text))
          .font(.system(size: level <= 2 ? 15 : 14, weight: .semibold))
      )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .bullet(let indent, let marker, let text):
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(marker)
          .foregroundStyle(.secondary)
        if Self.containsInlineMath(text) {
          mathAwareLineContent(text)
        } else {
          selectable(
            Text(inlineRendered(text))
              .font(.system(size: 14))
          )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.leading, CGFloat(indent) * 12)
    case .quote(let depth, let text):
      // 引用块：左侧竖条 + 灰字 + 按深度缩进
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Rectangle()
          .fill(Color.secondary.opacity(0.35))
          .frame(width: 3)
        if Self.containsInlineMath(text) {
          mathAwareLineContent(text)
            .foregroundStyle(.secondary)
        } else {
          selectable(
            Text(inlineRendered(text))
              .font(.system(size: 14))
              .foregroundStyle(.secondary)
          )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.leading, CGFloat(depth - 1) * 12)
    case .rule:
      // 显式矩形代替 Divider（实测 Divider 在此环境几乎不可见）
      Rectangle()
        .fill(Color.primary.opacity(0.3))
        .frame(height: 1)
        .padding(.vertical, 3)
    case .plain(let text):
      if Self.containsInlineMath(text) {
        mathAwareLineContent(text)
      } else {
        selectable(
          Text(inlineRendered(text))
            .font(.system(size: 14))
        )
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// 行内公式宽上限（pt）：超过则该公式段改为独占一行的块级展示
  private static let inlineMathMaxWidth: CGFloat = 240

  /// 含行内公式行的内容：短公式走行内位图；有超宽公式段时该段独占一行
  /// （行内位图不能换行，超宽必被裁剪——inline-long 实测教训）
  @ViewBuilder
  private func mathAwareLineContent(_ text: String) -> some View {
    let segments = SwiftMathRenderer.splitInlineMath(text)
    if !needsBlockLayout(segments) {
      selectable(SwiftMathInlineText.makeText(text) { inlineRendered($0) })
    } else {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
          switch segment {
          case .text(let string):
            selectable(
              Text(inlineRendered(string))
                .font(.system(size: 14))
            )
          case .math(let latex):
            SwiftMathBlockView(source: latex, fontSize: 14)
          }
        }
      }
    }
  }

  /// 行内公式是否需改独占一行：超宽，或超高（求和上下限/多行内容）——
  /// 行内位图不换行，超尺寸必然被裁（inline-long 实测教训）
  private func needsBlockLayout(_ segments: [SwiftMathRenderer.InlineSegment]) -> Bool {
    segments.contains { segment in
      guard case .math(let latex) = segment else { return false }
      let size = SwiftMathRenderer.measure(latex: latex, fontSize: 14, displayMode: false)
      return size.width > Self.inlineMathMaxWidth || size.height > 14 * 2
    }
  }

  private func inlineRendered(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
  }

  // MARK: - 虚拟列表高度模型

  /// NSTableView 的离屏行不能继续使用 SwiftUI List 的默认估算值；它会在行物化时
  /// 改写总高度，造成滚动条长度/位置跳变。这里用与渲染器相同的分块规则，借助
  /// CoreText 同步估算完整消息高度。视口 cell 仍使用上面的真实 SwiftUI 视图。
  static func estimatedHeight(markdown: String, width: CGFloat) -> CGFloat {
    let available = max(width, 40)
    let segments = MarkdownBlockSegmenter.segments(markdown)
    var heights: [CGFloat] = []
    for segment in segments {
      switch segment {
      case .paragraph(let text):
        heights.append(estimatedParagraphHeight(text, width: available))
      case .code(_, let code):
        let codeHeight = boundingHeight(
          code.isEmpty ? " " : code,
          font: .monospacedSystemFont(ofSize: 13, weight: .regular),
          width: max(available - 16, 20),
          lineSpacing: 0
        )
        heights.append(25 + 1 + 16 + codeHeight)
      }
    }
    return max(1, heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * 8)
  }

  private static func estimatedParagraphHeight(_ text: String, width: CGFloat) -> CGFloat {
    let blocks = parseBlocks(text)
    var heights: [CGFloat] = []
    for block in blocks {
      switch block {
      case .line(let line):
        heights.append(estimatedLineHeight(line, width: width))
      case .table(let rows):
        heights.append(estimatedTableHeight(rows, width: width))
      case .math(let source):
        let measured = SwiftMathRenderer.measure(latex: source, fontSize: 15, displayMode: true)
        heights.append(max(measured.height, 17) + 4)
      }
    }
    return max(1, heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * 3)
  }

  private static func estimatedLineHeight(_ line: String, width: CGFloat) -> CGFloat {
    switch classifyLine(line) {
    case .header(let level, let text):
      return boundingHeight(
        text.isEmpty ? " " : text,
        font: .systemFont(ofSize: level <= 2 ? 15 : 14, weight: .semibold),
        width: width,
        lineSpacing: 3
      )
    case .bullet(let indent, let marker, let text):
      let markerWidth = (marker as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
      return estimatedMathAwareHeight(
        text,
        width: max(width - CGFloat(indent) * 12 - markerWidth - 5, 20)
      )
    case .quote(let depth, let text):
      return estimatedMathAwareHeight(text, width: max(width - CGFloat(depth - 1) * 12 - 11, 20))
    case .rule:
      return 7
    case .plain(let text):
      if text.isEmpty { return 17 }
      return estimatedMathAwareHeight(text, width: width)
    }
  }

  private static func estimatedMathAwareHeight(_ text: String, width: CGFloat) -> CGFloat {
    guard containsInlineMath(text) else {
      return boundingHeight(text.isEmpty ? " " : text, font: .systemFont(ofSize: 14), width: width, lineSpacing: 3)
    }
    let segments = SwiftMathRenderer.splitInlineMath(text)
    let hasBlock = segments.contains { segment in
      guard case .math(let latex) = segment else { return false }
      let size = SwiftMathRenderer.measure(latex: latex, fontSize: 14, displayMode: false)
      return size.width > inlineMathMaxWidth || size.height > 28
    }
    if hasBlock {
      var heights: [CGFloat] = []
      for segment in segments {
        switch segment {
        case .text(let string):
          heights.append(boundingHeight(string.isEmpty ? " " : string, font: .systemFont(ofSize: 14), width: width, lineSpacing: 0))
        case .math(let latex):
          heights.append(max(SwiftMathRenderer.measure(latex: latex, fontSize: 14, displayMode: true).height + 4, 17))
        }
      }
      return heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * 2
    }
    let displayText = text.replacingOccurrences(of: "$", with: "")
    let textHeight = boundingHeight(displayText, font: .systemFont(ofSize: 14), width: width, lineSpacing: 3)
    let tallestMath = segments.compactMap { segment -> CGFloat? in
      guard case .math(let latex) = segment else { return nil }
      return SwiftMathRenderer.measure(latex: latex, fontSize: 14, displayMode: false).height
    }.max() ?? 0
    return max(textHeight, tallestMath)
  }

  private static func estimatedTableHeight(_ rows: [[String]], width: CGFloat) -> CGFloat {
    let columnCount = max(rows.map(\.count).max() ?? 0, 1)
    let columnWidth = max((width - CGFloat(columnCount - 1) * 14) / CGFloat(columnCount), 20)
    var height: CGFloat = 4
    for (rowIndex, row) in rows.enumerated() {
      let font = NSFont.systemFont(ofSize: 14, weight: rowIndex == 0 ? .semibold : .regular)
      let rowHeight = (0..<columnCount).map { column in
        boundingHeight(row.indices.contains(column) ? row[column] : " ", font: font, width: columnWidth, lineSpacing: 0)
      }.max() ?? 17
      height += rowHeight
      if rowIndex == 0 { height += 1 }
      if rowIndex < rows.count - 1 { height += 4 }
    }
    return height
  }

  private static func boundingHeight(
    _ text: String,
    font: NSFont,
    width: CGFloat,
    lineSpacing: CGFloat
  ) -> CGFloat {
    let lineHeight = max(ceil(font.ascender - font.descender + font.leading), 1)
    // 这里只建立滚动容器的高度表，不负责像素级文字绘制。TextKit 的
    // boundingRect 每次都会创建排版器，29 条历史消息在每个拖宽帧重跑会耗费
    // 40–50ms。按字形类别累计近似 advance；Markdown 标记本身仍计入宽度，
    // 已提供少量保守余量，同时整个过程只做线性数值运算。
    let effectiveWidth = max(width, 1)
    let visualLines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
      let advance = line.unicodeScalars.reduce(CGFloat.zero) { partial, scalar in
        partial + estimatedAdvance(of: scalar, fontSize: font.pointSize)
      }
      return total + max(Int(ceil(advance / effectiveWidth)), 1)
    }
    return CGFloat(visualLines) * lineHeight + CGFloat(max(visualLines - 1, 0)) * lineSpacing
  }

  private static func estimatedAdvance(of scalar: Unicode.Scalar, fontSize: CGFloat) -> CGFloat {
    let value = scalar.value
    if value == 0x09 { return fontSize * 2 }
    if value == 0x20 { return fontSize * 0.32 }
    guard value < 0x80 else { return fontSize }
    switch Character(String(scalar)) {
    case "i", "l", "I", ".", ",", "'", "`", ":", ";", "!", "|":
      return fontSize * 0.28
    case "m", "w", "M", "W", "@", "#", "%", "&":
      return fontSize * 0.82
    case "0"..."9":
      return fontSize * 0.56
    case "A"..."Z":
      return fontSize * 0.62
    default:
      return fontSize * 0.52
    }
  }
}

/// 代码块：等宽字体 + 圆角底色 + 语言标 + 复制按钮
struct AICodeBlockView: View {
  let language: String?
  let code: String
  var allowsTextSelection = true
  @State private var didCopy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language ?? "code")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(code, forType: .string)
          didCopy = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
        } label: {
          Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .help("复制代码")
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      Divider()
      AIAttributedTextView(text: codeAttributedText, isSelectable: allowsTextSelection)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
  }

  private var codeAttributedText: NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(
      string: code,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph,
      ]
    )
  }
}

/// 普通回复与代码块使用原生 TextKit 视图：选择能力通过 `isSelectable` 原地
/// 切换，不创建 SwiftUI SelectionOverlay；整块文字仍可连续跨行选择。
private struct AIAttributedTextView: NSViewRepresentable {
  let text: NSAttributedString
  let isSelectable: Bool

  func makeNSView(context: Context) -> AIIntrinsicTextView {
    let textView = AIIntrinsicTextView()
    textView.configure(text: text, isSelectable: isSelectable)
    return textView
  }

  func updateNSView(_ textView: AIIntrinsicTextView, context: Context) {
    textView.configure(text: text, isSelectable: isSelectable)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: AIIntrinsicTextView,
    context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(width: width, height: nsView.height(for: width))
  }
}

private final class AIIntrinsicTextView: NSTextView {
  private var configuredText: NSAttributedString?

  init() {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    super.init(frame: .zero, textContainer: container)
    drawsBackground = false
    isEditable = false
    isRichText = false
    importsGraphics = false
    isHorizontallyResizable = false
    isVerticallyResizable = false
    textContainerInset = .zero
    container.lineFragmentPadding = 0
    container.widthTracksTextView = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func configure(text: NSAttributedString, isSelectable: Bool) {
    self.isSelectable = isSelectable
    guard configuredText?.isEqual(to: text) != true else { return }
    configuredText = text.copy() as? NSAttributedString
    textStorage?.setAttributedString(text)
    invalidateIntrinsicContentSize()
  }

  func height(for width: CGFloat) -> CGFloat {
    guard let textContainer, let layoutManager else { return 17 }
    textContainer.containerSize = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    return max(ceil(layoutManager.usedRect(for: textContainer).height), 17)
  }
}

#Preview {
  ScrollView {
    AIMessageTextView(markdown: """
      这是**加粗**与 `行内代码` 的段落。

      ```swift
      let a = 1
      print(a)
      ```

      未闭合围栏（流式半截）：

      ```python
      print("streaming
      """)
      .padding()
  }
  .frame(width: 320, height: 420)
}
