import SwiftUI

/// AI 回复的轻量 markdown 渲染（FR-AI.2）：围栏代码块自绘（等宽+底色+复制），
/// 其余段落经 AttributedString(markdown:) 渲染行内样式；失败回退纯文本。
struct AIMessageTextView: View {
  let markdown: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownBlockSegmenter.segments(markdown).enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .paragraph(let text):
          Text(inlineRendered(text))
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let code):
          AICodeBlockView(language: language, code: code)
        }
      }
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
        .font(.system(size: 12.5, design: .monospaced))
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
