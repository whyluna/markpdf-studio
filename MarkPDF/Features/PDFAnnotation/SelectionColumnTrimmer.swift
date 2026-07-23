import PDFKit

/// 划词选区的分栏裁剪（FR-AI.1 体验修复）：PDFKit 拖拽选区按矩形覆盖，
/// 双栏论文在右栏划词会把左栏文字一并选中（甚至跨页边形成大片三角选中区）。
/// 拖拽结束（mouseUp）时按起止点所在栏裁剪：
/// 起止在同一栏 → 仅保留该栏的行；跨栏拖拽视为有意（阅读顺序），保持原选区。
enum SelectionColumnTrimmer {
  /// 栏聚类合并容差（页坐标 pt）：相邻行水平间隙小于该值视为同一栏（论文栏间距通常 > 15pt）
  static let clusterGap: CGFloat = 12

  /// 纯逻辑核心：给定行包围盒（页坐标）与拖拽起止点（页坐标），返回应保留的行下标。
  /// 规则：行按水平区间聚成若干栏；起止点落在同一栏且栏数 > 1 → 仅保留该栏行；否则全保留。
  static func keptLineIndices(lineBounds: [CGRect], dragStart: NSPoint, dragEnd: NSPoint) -> [Int] {
    guard lineBounds.count > 1 else { return Array(lineBounds.indices) }
    // 水平区间按 minX 排序，合并重叠/近邻区间 → 栏
    struct Cluster { var minX: CGFloat; var maxX: CGFloat; var lines: [Int] }
    var clusters: [Cluster] = []
    for (index, rect) in lineBounds.enumerated().sorted(by: { $0.element.minX < $1.element.minX }) {
      if var last = clusters.last, rect.minX - last.maxX <= clusterGap {
        last.maxX = max(last.maxX, rect.maxX)
        last.lines.append(index)
        clusters[clusters.count - 1] = last
      } else {
        clusters.append(Cluster(minX: rect.minX, maxX: rect.maxX, lines: [index]))
      }
    }
    guard clusters.count > 1 else { return Array(lineBounds.indices) }
    func clusterIndex(at point: NSPoint) -> Int? {
      clusters.firstIndex { point.x >= $0.minX - 4 && point.x <= $0.maxX + 4 }
    }
    guard let start = clusterIndex(at: dragStart), start == clusterIndex(at: dragEnd) else {
      // 跨栏拖拽或起止落在栏外空白：视为有意跨栏（阅读顺序），保持原选区
      return Array(lineBounds.indices)
    }
    return clusters[start].lines.sorted()
  }

  /// 拖拽结束：按需裁剪 PDFView 当前选区（起止点为视图坐标；dragStart 为 nil 时不动）
  @MainActor
  static func trimSelection(of pdfView: PDFView, dragStart: NSPoint?, dragEnd: NSPoint) {
    guard let dragStart,
      let selection = pdfView.currentSelection,
      let document = pdfView.document
    else { return }
    let trimmed = PDFSelection(document: document)
    var changed = false
    for page in selection.pages {
      let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
      guard lines.count > 1 else {
        lines.forEach { trimmed.add($0) }
        continue
      }
      let kept = keptLineIndices(
        lineBounds: lines.map { $0.bounds(for: page) },
        dragStart: pdfView.convert(dragStart, to: page),
        dragEnd: pdfView.convert(dragEnd, to: page)
      )
      if kept.count != lines.count { changed = true }
      for index in kept { trimmed.add(lines[index]) }
    }
    if changed {
      pdfView.setCurrentSelection(trimmed, animate: false)
    }
  }
}
