import Foundation
import PDFKit

/// 全文搜索结果（FR-6.2）：一个文件一条（首命中预览 + 总命中数）。
struct FullTextSearchResult: Identifiable, Equatable {
  let id = UUID()
  let url: URL
  let kind: FileNode.Kind
  /// md 命中行号 / pdf 命中页码（均 1 起）
  let location: Int
  /// 首命中上下文摘录
  let snippet: String
  /// 相关度：全文件命中次数
  let score: Int

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// 全文搜索（FR-6.2）：md 按行匹配 + PDF 页内提取文本匹配；后台线程执行（开发规范 §3.3）。
/// 纯函数实现，直接可测；取消检查由调用方按文件粒度注入。
enum FullTextSearch {
  /// 结果上限
  static let maxResults = 50
  /// 摘录上下文字符半径
  static let snippetRadius = 40
  /// 跳过的超大文件（2MB；与开发规范 §9.4 编辑器降级阈值一致）
  static let maxFileBytes = 2 * 1024 * 1024
  /// 跳过的超大 PDF（100MB）：整本扫描件常见几十 MB，不设上限时 PDFDocument 载入 +
  /// 逐页文本提取会把后台搜索拖死；超出直接跳过（该文件不出现在结果中，与超大 md 同口径）
  static let maxPDFBytes = 100 * 1024 * 1024
  /// PDF 页循环的取消检查间隔（页）：兼顾响应速度与每页一次闭包调用的开销
  static let pdfCancellationCheckInterval = 20

  /// 在 files（md/pdf）中搜索 query（大小写不敏感），按相关度（命中数）降序。
  /// isCancelled 每处理一个文件检查一次，返回 true 即中止并返回已收集结果。
  static func search(query: String, files: [URL], isCancelled: () -> Bool) -> [FullTextSearchResult] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    var results: [FullTextSearchResult] = []
    for url in files {
      if isCancelled() { break }
      let kind = FileNode.kind(for: url, isDirectory: false)
      let result: FullTextSearchResult?
      switch kind {
      case .markdown:
        result = searchMarkdown(url: url, needle: needle)
      case .pdf:
        result = searchPDF(url: url, needle: needle, isCancelled: isCancelled)
      default:
        result = nil
      }
      if let result { results.append(result) }
      if results.count >= maxResults { break }
    }
    return results.sorted { a, b in
      a.score != b.score ? a.score > b.score : a.url.path < b.url.path
    }
  }

  // MARK: - Markdown

  /// md 文件大小是否在搜索上限内（先 stat 后读盘：超限文件不整读进内存，
  /// 与 PDF 路径的 isPDFWithinSizeLimit 口径一致）。读取失败按不超限处理（交由读盘失败兜底）
  static func isMarkdownWithinSizeLimit(_ url: URL) -> Bool {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    return (size ?? 0) <= maxFileBytes
  }

  static func searchMarkdown(url: URL, needle: String) -> FullTextSearchResult? {
    guard isMarkdownWithinSizeLimit(url),
      let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    var hits = 0
    var firstLine = 0
    var firstSnippet = ""
    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
      var searchRange = line.startIndex..<line.endIndex
      // 逐处命中计数（一行多处全算）
      while let range = line.range(of: needle, options: .caseInsensitive, range: searchRange) {
        hits += 1
        if firstLine == 0 {
          firstLine = index + 1
          firstSnippet = snippet(in: line, around: range)
        }
        searchRange = range.upperBound..<line.endIndex
      }
    }
    guard hits > 0 else { return nil }
    return FullTextSearchResult(
      url: url, kind: .markdown, location: firstLine, snippet: firstSnippet, score: hits)
  }

  // MARK: - PDF

  /// PDF 文件大小是否在搜索上限内（纯函数，可测）。
  /// 读取失败按不超限处理：交由 PDFDocument 载入失败兜底返回 nil。
  static func isPDFWithinSizeLimit(_ url: URL) -> Bool {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    return (size ?? 0) <= maxPDFBytes
  }

  /// 页循环内每 pdfCancellationCheckInterval 页检查一次 isCancelled；
  /// 取消即放弃该文件（返回 nil），与外层"当前文件不收录"语义一致。
  static func searchPDF(url: URL, needle: String, isCancelled: () -> Bool = { false }) -> FullTextSearchResult? {
    guard isPDFWithinSizeLimit(url), let document = PDFDocument(url: url) else { return nil }
    var hits = 0
    var firstPage = 0
    var firstSnippet = ""
    for pageIndex in 0..<document.pageCount {
      if pageIndex % pdfCancellationCheckInterval == 0, isCancelled() { return nil }
      guard let pageText = document.page(at: pageIndex)?.string, !pageText.isEmpty else { continue }
      var searchRange = pageText.startIndex..<pageText.endIndex
      while let range = pageText.range(of: needle, options: .caseInsensitive, range: searchRange) {
        hits += 1
        if firstPage == 0 {
          firstPage = pageIndex + 1
          firstSnippet = snippet(in: pageText, around: range)
        }
        searchRange = range.upperBound..<pageText.endIndex
      }
    }
    guard hits > 0 else { return nil }
    return FullTextSearchResult(
      url: url, kind: .pdf, location: firstPage, snippet: firstSnippet, score: hits)
  }

  // MARK: - 多词合并计分（AI 工作区检索用）

  /// 内容只加载一次、对全部关键词计命中总数（此前逐词各扫一遍：6 词 = 6 倍读盘/解析）。
  /// 0 = 无命中或文件不可读/超限
  static func multiTermScore(url: URL, terms: [String]) -> Int {
    guard !terms.isEmpty, let text = extractText(url: url) else { return 0 }
    var total = 0
    for term in terms where !term.isEmpty {
      var searchRange = text.startIndex..<text.endIndex
      while let range = text.range(of: term, options: .caseInsensitive, range: searchRange) {
        total += 1
        searchRange = range.upperBound..<text.endIndex
      }
    }
    return total
  }

  /// 提取文件全文（md 读盘 / PDF 逐页拼接）；不可读或超限返回 nil
  static func extractText(url: URL) -> String? {
    switch FileNode.kind(for: url, isDirectory: false) {
    case .markdown:
      guard isMarkdownWithinSizeLimit(url), let data = try? Data(contentsOf: url) else { return nil }
      return String(data: data, encoding: .utf8)
    case .pdf:
      guard isPDFWithinSizeLimit(url), let document = PDFDocument(url: url) else { return nil }
      var text = ""
      for pageIndex in 0..<document.pageCount {
        text += (document.page(at: pageIndex)?.string ?? "") + "\n"
      }
      return text
    default:
      return nil
    }
  }

  // MARK: - 摘录

  /// 命中处前后各 snippetRadius 字符的摘录（首尾省略号、空白规整为一行）
  static func snippet(in text: String, around range: Range<String.Index>) -> String {
    let lower = text.index(range.lowerBound, offsetBy: -snippetRadius, limitedBy: text.startIndex) ?? text.startIndex
    let upper = text.index(range.upperBound, offsetBy: snippetRadius, limitedBy: text.endIndex) ?? text.endIndex
    var snippet = String(text[lower..<upper])
    if lower != text.startIndex { snippet = "…" + snippet }
    if upper != text.endIndex { snippet += "…" }
    return
      snippet
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
