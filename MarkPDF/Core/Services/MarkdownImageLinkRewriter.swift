import Foundation

/// Markdown 图片相对链接处理（FR-2.5）。
/// 两个用途：插入图片时算 md 目录 → 目标文件的相对路径；md 跨目录移动后重写链接保持指向原目标。
enum MarkdownImageLinkRewriter {
  /// 计算 base 目录到 target 文件的相对路径（空格转 %20，供 Markdown 链接使用）
  static func relativePath(from base: URL, to target: URL) -> String {
    let baseComponents = base.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    var common = 0
    while common < min(baseComponents.count, targetComponents.count),
      baseComponents[common] == targetComponents[common]
    {
      common += 1
    }
    let ups = Array(repeating: "..", count: baseComponents.count - common)
    let path = (ups + targetComponents[common...]).joined(separator: "/")
    return path.replacingOccurrences(of: " ", with: "%20")
  }

  /// md 从 oldDir 移到 newDir 后，重写其中的相对图片链接（保持指向同一绝对目标）。
  /// 只动相对路径链接：http(s)://、data:、绝对路径、锚点原样保留。
  static func rewrite(markdown: String, fromOldDir oldDir: URL, toNewDir newDir: URL) -> String {
    // 匹配 ![alt](dest) 与 ![alt](dest "title")：只替换 dest 部分
    let pattern = #"!\[[^\]]*\]\(\s*<?([^\s>)]+)>?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
    let nsRange = NSRange(markdown.startIndex..., in: markdown)
    var result = markdown
    // 倒序替换，避免偏移失效
    for match in regex.matches(in: markdown, range: nsRange).reversed() {
      guard let destRange = Range(match.range(at: 1), in: markdown) else { continue }
      let dest = String(markdown[destRange])
      if shouldSkip(dest) { continue }
      let decoded = dest.removingPercentEncoding ?? dest
      let target = oldDir.appendingPathComponent(decoded).standardizedFileURL
      let newDest = relativePath(from: newDir, to: target)
      if newDest != dest {
        result.replaceSubrange(destRange, with: newDest)
      }
    }
    return result
  }

  private static func shouldSkip(_ dest: String) -> Bool {
    dest.contains("://") || dest.hasPrefix("data:") || dest.hasPrefix("/") || dest.hasPrefix("#")
  }
}
