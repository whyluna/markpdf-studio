import Foundation

/// AI 回复的轻量 markdown 分块（FR-AI.2）：仅按 ``` 围栏切段落/代码块，
/// 行内样式交给 AttributedString(markdown:) 渲染。
/// 流式安全：未闭合围栏视为代码块直到文末（增量渲染不闪烂）
enum MarkdownBlockSegmenter {
  enum Segment: Equatable {
    case paragraph(String)
    case code(language: String?, code: String)
  }

  static func segments(_ markdown: String) -> [Segment] {
    var result: [Segment] = []
    var paragraphLines: [String] = []
    var codeLines: [String] = []
    var codeLanguage: String?
    var inFence = false

    func flushParagraph() {
      let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { result.append(.paragraph(text)) }
      paragraphLines = []
    }

    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        if inFence {
          result.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
          codeLines = []
          codeLanguage = nil
          inFence = false
        } else {
          flushParagraph()
          let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
          codeLanguage = lang.isEmpty ? nil : lang
          inFence = true
        }
        continue
      }
      if inFence {
        codeLines.append(String(line))
      } else {
        paragraphLines.append(String(line))
      }
    }
    if inFence {
      // 流式半截围栏：已到内容全算代码块
      result.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
    } else {
      flushParagraph()
    }
    return result
  }
}
