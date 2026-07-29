import SwiftUI

/// AI 回复的轻量 markdown 渲染（FR-AI.2）：围栏代码块自绘（等宽+底色+复制），
/// 段落按行解析块级结构——标题/无序与有序列表/分割线/管道表格/$$ 块级公式
/// （AttributedString 的 inlineOnly 模式不处理块级结构），行内样式仍走
/// AttributedString(markdown:)；失败回退纯文本。
struct AIMessageTextView: View {
  let markdown: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownBlockSegmenter.segments(markdown).enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .paragraph(let text):
          paragraphView(text)
        case .code(let language, let code):
          AICodeBlockView(language: language, code: code)
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
    let blocks = Self.parseBlocks(text)
    return VStack(alignment: .leading, spacing: 3) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
  }

  @ViewBuilder
  private func blockView(_ block: Block) -> some View {
    switch block {
    case .line(let line):
      lineView(line)
    case .table(let rows):
      tableView(rows)
    case .math(let source):
      mathView(source)
    }
  }

  /// 管道表格：表头加粗 + 分隔线 + 数据行（列数不齐补空）
  private func tableView(_ rows: [[String]]) -> some View {
    let columnCount = rows.map(\.count).max() ?? 0
    return Grid(horizontalSpacing: 14, verticalSpacing: 4) {
      if let header = rows.first {
        GridRow {
          ForEach(0..<columnCount, id: \.self) { column in
            Text(inlineRendered(header.indices.contains(column) ? header[column] : ""))
              .font(.system(size: 14, weight: .semibold))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        // 表头分隔线：显式矩形（Divider 在此环境几乎不可见）
        Rectangle()
          .fill(Color.primary.opacity(0.3))
          .frame(height: 1)
      }
      ForEach(Array(rows.indices.dropFirst()), id: \.self) { rowIndex in
        GridRow {
          ForEach(0..<columnCount, id: \.self) { column in
            Text(inlineRendered(rows[rowIndex].indices.contains(column) ? rows[rowIndex][column] : ""))
              .font(.system(size: 14))
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
      Text(inlineRendered(text))
        .font(.system(size: level <= 2 ? 15 : 14, weight: .semibold))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .bullet(let indent, let marker, let text):
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(marker)
          .foregroundStyle(.secondary)
        if Self.containsInlineMath(text) {
          mathAwareLineContent(text)
        } else {
          Text(inlineRendered(text))
            .font(.system(size: 14))
            .textSelection(.enabled)
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
          Text(inlineRendered(text))
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
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
        Text(inlineRendered(text))
          .font(.system(size: 14))
          .textSelection(.enabled)
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
      SwiftMathInlineText.makeText(text) { inlineRendered($0) }
        .textSelection(.enabled)
    } else {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
          switch segment {
          case .text(let string):
            Text(inlineRendered(string))
              .font(.system(size: 14))
              .textSelection(.enabled)
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
}

/// 代码块：等宽字体 + 圆角底色 + 语言标 + 复制按钮
struct AICodeBlockView: View {
  let language: String?
  let code: String
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
      Text(code)
        .font(.system(size: 13, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
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
