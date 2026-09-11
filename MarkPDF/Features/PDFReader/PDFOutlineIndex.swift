import Foundation
import PDFKit

/// 目录的值类型快照：后台加载时提取，界面滚动/拖宽不重新解析 PDF。
/// 仅用于导航，不向 PDF 写入推断出来的书签。
struct PDFOutlineIndex: Equatable, Sendable {
  enum Source: Sendable { case embedded, linkedContents, none }

  struct Target: Equatable, Sendable {
    let pageIndex: Int
    let point: CGPoint
    let zoom: CGFloat

    func destination(in document: PDFDocument) -> PDFDestination? {
      guard pageIndex >= 0, pageIndex < document.pageCount,
        let page = document.page(at: pageIndex) else { return nil }
      let destination = PDFDestination(page: page, at: point)
      destination.zoom = zoom
      return destination
    }
  }

  struct Entry: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let level: Int
    let target: Target?
    var page: Int? { target.map { $0.pageIndex + 1 } }
  }

  let source: Source
  let entries: [Entry]
  static let empty = PDFOutlineIndex(source: .none, entries: [])

  // 查找开头的目录页，有界扫描避免普通长 PDF 全文解析；找到目录后允许跨空白页续接。
  static let scanPageLimit = 24
  private static let entryLimit = 4000

  static func build(document: PDFDocument, isCancelled: () -> Bool = { false }) -> PDFOutlineIndex {
    var native: [Entry] = []
    var visited = Set<ObjectIdentifier>()
    func walk(_ node: PDFOutline, level: Int) {
      guard level < 64, native.count < entryLimit, !isCancelled(),
        visited.insert(ObjectIdentifier(node)).inserted else { return }
      native.append(Entry(id: native.count, title: node.label ?? "", level: level,
        target: target(node.destination ?? (node.action as? PDFActionGoTo)?.destination, in: document)))
      for index in 0..<node.numberOfChildren {
        if let child = node.child(at: index) { walk(child, level: level + 1) }
      }
    }
    if let root = document.outlineRoot {
      for index in 0..<root.numberOfChildren {
        if let child = root.child(at: index) { walk(child, level: 0) }
      }
    }
    if !native.isEmpty { return PDFOutlineIndex(source: .embedded, entries: native) }

    var all: [Candidate] = []
    var gapPages = 0
    for pageIndex in 0..<min(scanPageLimit, document.pageCount) {
      guard !isCancelled(), all.count < entryLimit else { break }
      guard let page = document.page(at: pageIndex) else { continue }
      let candidates = linkedRows(on: page, document: document)
      let hasHeading = (page.string ?? "").components(separatedBy: .newlines).contains {
        let title = $0.filter { !$0.isWhitespace }.lowercased()
        return ["目录", "目錄", "contents", "tableofcontents", "contents(continued)", "目录（续）", "目錄（續）"].contains(title)
      }
      let leaderCount = candidates.filter(\.hasLeader).count
      // 普通正文里的交叉引用、脚注、外部网站不能成为目录。无标题时要求强点线证据。
      let isStart = (hasHeading && candidates.count >= 2)
        || (candidates.count >= 4 && leaderCount * 4 >= candidates.count * 3)
      let isContinuation = !all.isEmpty && !candidates.isEmpty
        && leaderCount * 2 >= candidates.count
      if isStart || isContinuation {
        all.append(contentsOf: candidates.prefix(entryLimit - all.count))
        gapPages = 0
      } else if !all.isEmpty {
        gapPages += 1
        if gapPages >= 2 { break }
      }
    }
    guard !all.isEmpty else { return .empty }
    // 同一目录跨页时统一缩进档位；容忍字体取字边界/页边距的少量误差。
    var indents: [CGFloat] = []
    for x in all.map(\.indent).sorted() {
      if indents.last.map({ x - $0 > 8 }) ?? true { indents.append(x) }
    }
    let entries = all.enumerated().map { index, row in
      let level = indents.lastIndex(where: { row.indent >= $0 - 4 }) ?? 0
      return Entry(id: index, title: row.title, level: min(level, 6), target: row.target)
    }
    return PDFOutlineIndex(source: .linkedContents, entries: entries)
  }

  private struct Candidate {
    let title: String
    let target: Target
    let bounds: CGRect
    let indent: CGFloat
    let hasLeader: Bool
  }

  private static func target(_ destination: PDFDestination?, in document: PDFDocument) -> Target? {
    guard let destination, let page = destination.page else { return nil }
    let index = document.index(for: page)
    guard index != NSNotFound, index >= 0, index < document.pageCount else { return nil }
    let point = destination.point
    // PDFKit 用一个很大的有限值表达 XYZ 的 null（保持当前位置），必须保留其语义。
    guard point.x.isFinite, point.y.isFinite else { return nil }
    return Target(pageIndex: index, point: point,
      zoom: destination.zoom.isFinite ? destination.zoom : kPDFDestinationUnspecifiedValue)
  }

  private static func linkedRows(on page: PDFPage, document: PDFDocument) -> [Candidate] {
    let crop = page.bounds(for: .cropBox)
    var rows: [Candidate] = []
    let links = page.annotations.filter { $0.type?.replacingOccurrences(of: "/", with: "") == "Link" }
      .sorted { $0.bounds.midY == $1.bounds.midY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY }
    for link in links.prefix(entryLimit * 2) {
      guard let target = target(link.destination ?? (link.action as? PDFActionGoTo)?.destination, in: document),
        !link.bounds.isEmpty, !link.bounds.isNull,
        [link.bounds.minX, link.bounds.minY, link.bounds.width, link.bounds.height].allSatisfy(\.isFinite)
      else { continue }
      let rect = link.bounds.insetBy(dx: 0, dy: min(1, link.bounds.height * 0.1))
      var selection = page.selection(for: rect)
      var raw = selection?.string ?? ""
      var title = cleanedTitle(raw)
      // 有些导出器只给右侧页码加链接。沿同一行往左读取标题，仍以链接目标定位。
      if title.isEmpty {
        let rowRect = CGRect(x: crop.minX, y: rect.minY, width: rect.maxX - crop.minX, height: rect.height)
        selection = page.selection(for: rowRect)
        raw = selection?.string ?? ""
        title = cleanedTitle(raw)
      }
      guard !title.isEmpty, title.count <= 240,
        raw.components(separatedBy: .newlines).count <= 4 else { continue }
      let bounds = selection?.bounds(for: page) ?? rect
      let row = Candidate(title: title, target: target, bounds: bounds,
        indent: bounds.minX - crop.minX, hasLeader: raw.range(of: leaderPattern, options: .regularExpression) != nil)
      // 标题和页码通常是两个链接，区域甚至会略有重叠；同一行同目标只保留完整标题。
      if !rows.contains(where: {
        $0.target == target && $0.title == title
          && abs($0.bounds.midY - bounds.midY) < max(3, min($0.bounds.height, bounds.height) * 0.45)
      }) {
        rows.append(row)
      }
    }
    return rows
  }

  private static let leaderPattern = #"[.·•…⋅．․](?:[\s.·•…⋅．․]){2,}(?:[0-9０-９ivxlcdmIVXLCDM]+)?\s*$"#

  static func cleanedTitle(_ source: String) -> String {
    var title = source.replacingOccurrences(of: leaderPattern, with: "", options: .regularExpression)
    title = title.replacingOccurrences(of: #"\s{2,}[0-9０-９]+\s*$"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if title.range(of: #"^[\s.·•…⋅．․0-9０-９ivxlcdmIVXLCDM]+$"#, options: .regularExpression) != nil { return "" }
    return title
  }
}
