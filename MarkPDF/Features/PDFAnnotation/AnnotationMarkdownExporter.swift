import Foundation

/// 标注导出为 Markdown 的纯格式化逻辑（FR-4.8）。
/// 与 UI/文件 IO 解耦，供单元测试直接覆盖。
enum AnnotationMarkdownExporter {
  /// 单条标注的导出行：`- [p.N] 摘录`；有命名时追加 ` — 名称`；两者皆空返回 nil（不导出空行）
  static func line(for item: AnnotationItem) -> String? {
    let excerpt = item.excerpt
    let name = item.name
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let text: String
    switch (excerpt.isEmpty, name.isEmpty) {
    case (true, true):
      return nil
    case (false, true):
      text = excerpt
    case (true, false):
      text = name
    case (false, false):
      text = "\(excerpt) — \(name)"
    }
    return "- [p.\(item.pageLabel)] \(text)"
  }

  /// 全部标注的导出行：按页码分组（页内视觉顺序），与列表面板排序口径一致
  static func lines(for items: [AnnotationItem]) -> [String] {
    AnnotationSort.page.sort(items).compactMap(line(for:))
  }

  /// 合并到目标笔记：新文件带标题头；追加时按行内容精确去重（增量导出不重复，FR-4.8 验收）。
  /// 返回合并后的完整内容与本次新增行数（addedCount = 0 表示无需写盘）。
  static func mergedContent(
    existing: String?,
    pdfBaseName: String,
    newLines: [String]
  ) -> (content: String, addedCount: Int) {
    guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      let body = newLines.joined(separator: "\n")
      return ("# \(pdfBaseName) 标注\n\n\(body)\n", newLines.count)
    }
    let existingLines = Set(
      existing.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
    let additions = newLines.filter { !existingLines.contains($0) }
    guard !additions.isEmpty else { return (existing, 0) }
    var content = existing
    while content.hasSuffix("\n") { content.removeLast() }
    content += "\n\n" + additions.joined(separator: "\n") + "\n"
    return (content, additions.count)
  }
}
