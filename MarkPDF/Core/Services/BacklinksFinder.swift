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
    var result: [Backlink] = []
    for file in mdFiles {
      // 排除自引用
      guard file.standardizedFileURL != normalizedTarget,
        let data = try? Data(contentsOf: file), data.count <= maxFileBytes,
        let content = String(data: data, encoding: .utf8)
      else { continue }
      let nsRange = NSRange(content.startIndex..., in: content)
      for match in regex.matches(in: content, range: nsRange) {
        // 排除图片 ![...](...)
        if match.range.location > 0 {
          let before = content.index(content.startIndex, offsetBy: match.range.location - 1)
          if content[before] == "!" { continue }
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
