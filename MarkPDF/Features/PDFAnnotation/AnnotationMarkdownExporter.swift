import Foundation

/// 标注导出为 Markdown 的纯格式化逻辑（FR-4.8）。
/// 与 UI/文件 IO 解耦，供单元测试直接覆盖。
enum AnnotationMarkdownExporter {
  /// 单条标注的导出行：`- [p.N](回链) 摘录`；有命名时追加 ` — 名称`；两者皆空返回 nil（不导出空行）。
  /// pageLink 生成页码回链（FR-5.3 格式 `pdf相对路径#page=N`，由调用方按目标笔记位置计算）
  static func line(for item: AnnotationItem, pageLink: (Int) -> String) -> String? {
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
    return "- [p.\(item.pageLabel)](\(pageLink(item.pageLabel))) \(text)"
  }

  /// 全部标注的导出行：按页码分组（页内视觉顺序），与列表面板排序口径一致
  static func lines(for items: [AnnotationItem], pageLink: (Int) -> String) -> [String] {
    AnnotationSort.page.sort(items).compactMap { line(for: $0, pageLink: pageLink) }
  }

  /// 合并到目标笔记：新文件带标题头；追加时按行内容精确去重（增量导出不重复，FR-4.8 验收）；
  /// 旧格式行（无回链的 `- [p.N] 文本`）若与新行同页同文则就地升级为回链行。
  /// 返回合并后的完整内容与本次新增+升级行数（addedCount = 0 表示无需写盘）。
  static func mergedContent(
    existing: String?,
    pdfBaseName: String,
    newLines: [String]
  ) -> (content: String, addedCount: Int) {
    guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      let body = newLines.joined(separator: "\n")
      return ("# \(pdfBaseName) 标注\n\n\(body)\n", newLines.count)
    }
    var lines = existing.components(separatedBy: .newlines)
    var appended: [String] = []
    var addedCount = 0
    for newLine in newLines {
      if lines.contains(newLine) {
        continue  // 已有同格式行：去重跳过
      }
      if let plain = plainForm(of: newLine), let index = lines.firstIndex(of: plain) {
        lines[index] = newLine  // 旧格式行：就地升级为回链行
        addedCount += 1
        continue
      }
      appended.append(newLine)
    }
    addedCount += appended.count
    guard addedCount > 0 else { return (existing, 0) }
    var content = lines.joined(separator: "\n")
    if !appended.isEmpty {
      while content.hasSuffix("\n") { content.removeLast() }
      content += "\n\n" + appended.joined(separator: "\n") + "\n"
    }
    return (content, addedCount)
  }

  /// 回链行转纯文本行：`- [p.N](dest) 文本` → `- [p.N] 文本`（识别旧格式用）
  private static func plainForm(of line: String) -> String? {
    guard line.hasPrefix("- [p."),
      let open = line.range(of: "]("),
      let close = line.range(of: ") ", range: open.upperBound..<line.endIndex)
    else { return nil }
    return String(line[..<open.lowerBound]) + "] " + line[close.upperBound...]
  }
}
