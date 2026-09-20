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
    let fallback = DestinationFallback(document: document)
    for pageIndex in 0..<min(scanPageLimit, document.pageCount) {
      guard !isCancelled(), all.count < entryLimit else { break }
      guard let page = document.page(at: pageIndex) else { continue }
      let candidates = linkedRows(on: page, document: document, fallback: fallback)
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

  /// CG 层 /Dest 回退解析（OS 回归兜底）：新版 macOS PDFKit 把「被读取过 destination
  /// 的链接」写回时物化成不可解析的名字令牌（/A /D [ /#xx… /XYZ … ]），按规范 /A 优先
  /// 于 /Dest → PDFKit 侧 destination.page 变 nil；而文件里原始 /Dest 页引用完好。
  /// 此回退经 CG 直接读取它恢复目标（CGPDF 的取值 API 会透明解引用间接页引用）。
  final class DestinationFallback {
    /// 页字典引用 → PDFKit 页索引（惰性建立；CF 类型不可哈希，线性 CFEqual）
    private var pageDicts: [(dict: CGPDFDictionaryRef, index: Int)]?
    private let document: PDFDocument

    init(document: PDFDocument) {
      self.document = document
    }

    func target(for link: PDFAnnotation, on page: PDFPage) -> Target? {
      guard let cgPage = page.pageRef, let cgDict = cgPage.dictionary else { return nil }
      var annotsRef: CGPDFArrayRef?
      guard CGPDFDictionaryGetArray(cgDict, "Annots", &annotsRef), let annots = annotsRef else { return nil }
      let bounds = link.bounds
      for i in 0..<CGPDFArrayGetCount(annots) {
        var annotDict: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(annots, i, &annotDict), let annot = annotDict else { continue }
        var subtype: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(annot, "Subtype", &subtype)
        guard subtype.map({ String(cString: $0) }) == "Link" else { continue }
        // 以 /Rect 匹配 PDFKit 链接（页空间同向，中心点容差 1pt）
        var rectRef: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annot, "Rect", &rectRef), let rect = rectRef,
          CGPDFArrayGetCount(rect) == 4 else { continue }
        var coords: [CGFloat] = []
        for j in 0..<4 {
          var n: CGFloat = 0
          if CGPDFArrayGetNumber(rect, j, &n) { coords.append(n) }
        }
        guard coords.count == 4 else { continue }
        let box = CGRect(x: coords[0], y: coords[1], width: coords[2] - coords[0], height: coords[3] - coords[1])
        guard abs(box.midX - bounds.midX) < 1, abs(box.midY - bounds.midY) < 1 else { continue }
        var destRef: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(annot, "Dest", &destRef), let dest = destRef,
          let fromDest = target(fromCG: dest)
        {
          return fromDest
        }
        var actionDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(annot, "A", &actionDict), let action = actionDict {
          var s: UnsafePointer<CChar>?
          CGPDFDictionaryGetName(action, "S", &s)
          guard s.map({ String(cString: $0) }) == "GoTo" else { continue }
          var dRef: CGPDFArrayRef?
          if CGPDFDictionaryGetArray(action, "D", &dRef), let d = dRef,
            let fromAction = target(fromCG: d)
          {
            return fromAction
          }
        }
      }
      return nil
    }

    /// /Dest 或 /A /D 数组：[页引用 /XYZ x y zoom]（XYZ 之外的 fit 类型只定位到页）
    private func target(fromCG dest: CGPDFArrayRef) -> Target? {
      guard CGPDFArrayGetCount(dest) >= 3 else { return nil }
      var pageDict: CGPDFDictionaryRef?
      // 名字令牌（损坏目的地的首元素）解析不出字典 → 放弃
      guard CGPDFArrayGetDictionary(dest, 0, &pageDict), let pageDict else { return nil }
      guard let index = pageIndex(of: pageDict) else { return nil }
      var fit: UnsafePointer<CChar>?
      CGPDFArrayGetName(dest, 1, &fit)
      guard fit.map({ String(cString: $0) }) == "XYZ" else {
        return Target(pageIndex: index, point: CGPoint(x: 0, y: 0), zoom: kPDFDestinationUnspecifiedValue)
      }
      var x: CGFloat = 0
      var y: CGFloat = 0
      CGPDFArrayGetNumber(dest, 2, &x)
      CGPDFArrayGetNumber(dest, 3, &y)
      var zoom = kPDFDestinationUnspecifiedValue
      var zoomValue: CGFloat = 0
      if CGPDFArrayGetCount(dest) > 4, CGPDFArrayGetNumber(dest, 4, &zoomValue), zoomValue > 0 { zoom = zoomValue }
      return Target(pageIndex: index, point: CGPoint(x: x, y: y), zoom: zoom)
    }

    private func pageIndex(of dict: CGPDFDictionaryRef) -> Int? {
      if pageDicts == nil {
        pageDicts = (0..<document.pageCount).compactMap { i in
          document.page(at: i)?.pageRef?.dictionary.map { (dict: $0, index: i) }
        }
      }
      return pageDicts?.first { CFEqual($0.dict as CFTypeRef, dict as CFTypeRef) }?.index
    }
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

  private static func linkedRows(on page: PDFPage, document: PDFDocument, fallback: DestinationFallback) -> [Candidate] {
    let crop = page.bounds(for: .cropBox)
    var rows: [Candidate] = []
    let links = page.annotations.filter { $0.type?.replacingOccurrences(of: "/", with: "") == "Link" }
      .sorted { $0.bounds.midY == $1.bounds.midY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY }
    for link in links.prefix(entryLimit * 2) {
      let pdfKitTarget = target(link.destination ?? (link.action as? PDFActionGoTo)?.destination, in: document)
      guard let target = pdfKitTarget ?? fallback.target(for: link, on: page),
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
