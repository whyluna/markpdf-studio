import SwiftUI

/// AI 回复的轻量 markdown 渲染（FR-AI.2）：围栏代码块自绘（等宽+底色+复制），
/// 段落按行解析——标题/无序与有序列表成块渲染（AttributedString 的
/// inlineOnly 模式不处理块级结构，"- "/"## " 会原文显示），行内样式仍走
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
    case plain(String)
  }

  /// 行分类：# 标题（允许前导空格，空 # 行守卫）/ 无序列表（- * +）/
  /// 有序列表（1.）/ 普通行；缩进每 2 空格一级，Tab 计一级
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

  private func paragraphView(_ text: String) -> some View {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return VStack(alignment: .leading, spacing: 3) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        lineView(line)
      }
    }
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
        Text(inlineRendered(text))
          .font(.system(size: 14))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, CGFloat(indent) * 12)
    case .plain(let text):
      Text(inlineRendered(text))
        .font(.system(size: 14))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
