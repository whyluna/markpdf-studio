import Foundation
import PDFKit

/// 文档结构切节（FR-AI.2 v1.2：结构选节 + 两遍路由的地基）。
/// md 按标题树、PDF 按书签（无书签退化每页一节）；节带锚点（§标题 / p.页码）
/// 供回答引用与 UI 跳转（锚点引用，D4）。
struct DocumentSection: Equatable {
  /// 节标题（md 标题文本 / PDF 书签标题 / 页码）
  let title: String
  /// 锚点标记：md "§标题"；PDF "p.起-止"
  let anchor: String
  let text: String
}

enum DocumentSectioner {
  /// 无标题结构时的退化分块大小（字符）
  static let fallbackChunkChars = 4_000

  /// Markdown 按标题行切节（#–######）；无任何标题退化为定长分块
  static func fromMarkdown(_ text: String) -> [DocumentSection] {
    var sections: [DocumentSection] = []
    var currentTitle = ""
    var currentLines: [String] = []
    var inFence = false

    func flush() {
      let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty || !currentTitle.isEmpty else { return }
      let title = currentTitle.isEmpty ? String(localized: "开头") : currentTitle
      sections.append(DocumentSection(title: title, anchor: "§\(title)", text: body))
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") { inFence.toggle() }
      if !inFence, let title = headingTitle(of: trimmed) {
        flush()
        currentTitle = title
        currentLines = []
      } else {
        currentLines.append(String(line))
      }
    }
    flush()
    if sections.count <= 1 {
      return chunked(text, label: { String(localized: "第 \($0) 段") })
    }
    return sections
  }

  /// PDF 按书签切节（取全部叶子/顶层书签的页范围）；无书签退化为每页一节
  @MainActor
  static func fromPDF(_ document: PDFDocument) -> [DocumentSection] {
    let pageCount = document.pageCount
    guard pageCount > 0 else { return [] }
    let bookmarks = flattenedBookmarks(document)
    if bookmarks.count >= 2 {
      var sections: [DocumentSection] = []
      for (index, bookmark) in bookmarks.enumerated() {
        let startPage = bookmark.page
        let endPage = index + 1 < bookmarks.count ? max(bookmarks[index + 1].page - 1, startPage) : pageCount - 1
        var text = ""
        for page in startPage...endPage {
          text += (document.page(at: page)?.string ?? "") + "\n"
        }
        sections.append(DocumentSection(
          title: bookmark.title,
          anchor: startPage == endPage ? "p.\(startPage + 1)" : "p.\(startPage + 1)-\(endPage + 1)",
          text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
      }
      return sections
    }
    // 无书签：每页一节
    return (0..<pageCount).map { index in
      DocumentSection(
        title: String(localized: "第 \(index + 1) 页"),
        anchor: "p.\(index + 1)",
        text: (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }

  /// 目录摘要（路由第一遍的输入）：编号 + 锚点 + 标题 + 首句片段
  static func outlineDigest(_ sections: [DocumentSection], leadChars: Int = 60) -> String {
    sections.enumerated().map { index, section in
      let lead = section.text.prefix(leadChars).replacingOccurrences(of: "\n", with: " ")
      return "\(index). [\(section.anchor)] \(section.title) — \(lead)"
    }.joined(separator: "\n")
  }

  /// 按选中节编号拼装（每节带锚点标记，供回答引用），拼到预算即停
  static func assemble(sections: [DocumentSection], picked: [Int], budget: Int) -> String {
    var result = ""
    for index in picked where sections.indices.contains(index) {
      guard result.count < budget else { break }
      let section = sections[index]
      let block = "[\(section.anchor)] \(section.title)\n\(section.text)\n\n"
      result += String(block.prefix(max(budget - result.count, 0)))
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - 私有

  private static func headingTitle(of line: String) -> String? {
    guard line.hasPrefix("#") else { return nil }
    let marks = line.prefix(while: { $0 == "#" })
    guard marks.count <= 6, line.dropFirst(marks.count).first == " " else { return nil }
    let title = line.dropFirst(marks.count).trimmingCharacters(in: .whitespaces)
    return title.isEmpty ? nil : title
  }

  private static func chunked(_ text: String, label: (Int) -> String) -> [DocumentSection] {
    guard !text.isEmpty else { return [] }
    var sections: [DocumentSection] = []
    var start = text.startIndex
    var number = 1
    while start < text.endIndex {
      let end = text.index(start, offsetBy: fallbackChunkChars, limitedBy: text.endIndex) ?? text.endIndex
      let title = label(number)
      sections.append(DocumentSection(title: title, anchor: "§\(title)", text: String(text[start..<end])))
      start = end
      number += 1
    }
    return sections
  }

  @MainActor
  private static func flattenedBookmarks(_ document: PDFDocument) -> [(title: String, page: Int)] {
    guard let root = document.outlineRoot else { return [] }
    var result: [(String, Int)] = []
    func walk(_ node: PDFOutline, depth: Int) {
      // 只取前两层（论文的章 + 节足够；更深层目录摘要会爆）
      for index in 0..<node.numberOfChildren {
        guard let child = node.child(at: index) else { continue }
        if let page = child.destination?.page, let label = child.label, !label.isEmpty {
          result.append((label, document.index(for: page)))
        }
        if depth < 1 { walk(child, depth: depth + 1) }
      }
    }
    walk(root, depth: 0)
    // 按页码排序去重（书签乱序/重复页防御）
    return result.sorted { $0.1 < $1.1 }
  }
}
