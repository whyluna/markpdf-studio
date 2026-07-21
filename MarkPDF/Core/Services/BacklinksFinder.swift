import Foundation

/// 一条反向链接（FR-5.4）：某 md 文件通过 `[文本](路径)` 引用了目标文件
struct Backlink: Equatable {
  /// 引用来源（md 文件）
  let source: URL
  /// 链接显示文本
  let text: String
}

/// 反向链接查找（FR-5.4）：扫描工作区 md 文件的链接，解析后比对目标（纯函数，可测）。
/// 解析规则与 FR-5.3 一致：md 目录优先、工作区根目录回退。
enum BacklinksFinder {
  /// 跳过的超大文件（与全文搜索一致）
  static let maxFileBytes = 2 * 1024 * 1024

  static func find(target: URL, in mdFiles: [URL], workspaceRoot: URL?) -> [Backlink] {
    let pattern = #"\[([^\]]*)\]\(\s*<?([^)\s>]+)>?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let normalizedTarget = target.standardizedFileURL
    let targetName = target.lastPathComponent
    var result: [Backlink] = []
    for file in mdFiles {
      // 排除自引用
      guard file.standardizedFileURL != normalizedTarget,
        let data = try? Data(contentsOf: file), data.count <= maxFileBytes,
        let content = String(data: data, encoding: .utf8)
      else { continue }
      // 预筛：不含目标文件名的直接跳过（大工作区下避免全文正则 + 逐链接 resolve 的 syscall 开销）
      guard content.contains(targetName) else { continue }
      let nsRange = NSRange(content.startIndex..., in: content)
      for match in regex.matches(in: content, range: nsRange) {
        guard let matchRange = Range(match.range, in: content) else { continue }
        // 排除图片 ![...](...)（match.range 是 UTF-16 下标，必须先转 Range 再取字符，
        // 直接用 offsetBy 会在多字节文本中越界崩溃——真机踩坑）
        if matchRange.lowerBound > content.startIndex,
          content[content.index(before: matchRange.lowerBound)] == "!"
        {
          continue
        }
        guard let textRange = Range(match.range(at: 1), in: content),
          let destRange = Range(match.range(at: 2), in: content)
        else { continue }
        let dest = String(content[destRange])
        guard let link = MarkdownFileLink.parse(dest),
          let resolved = MarkdownFileLink.resolve(
            path: link.path,
            documentDir: file.deletingLastPathComponent(),
            workspaceRoot: workspaceRoot
          ),
          resolved.standardizedFileURL == normalizedTarget
        else { continue }
        let text = String(content[textRange])
        result.append(Backlink(source: file, text: text.isEmpty ? file.lastPathComponent : text))
      }
    }
    return result.sorted { $0.source.path < $1.source.path }
  }
}
