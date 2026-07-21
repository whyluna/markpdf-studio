import Foundation

/// md 中的文件回链（FR-5.3）：`[描述](xxx.pdf#page=N)` 的解析与路径解析（纯函数，可测）。
/// 解析规则：相对路径先按 md 所在目录解析，不存在则回退到工作区根目录。
struct MarkdownFileLink: Equatable {
  /// percent 解码后的路径（可能为相对或绝对）
  let path: String
  /// 页码（1 起；无 #page 片段为 nil）
  let page: Int?

  /// 解析链接 URL 字符串；非文件链接（http/data/mailto 等）返回 nil
  static func parse(_ urlString: String) -> MarkdownFileLink? {
    if urlString.contains("://") || urlString.hasPrefix("data:") || urlString.hasPrefix("mailto:") {
      return nil
    }
    let parts = urlString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let rawPath = String(parts[0])
    guard !rawPath.isEmpty else { return nil }
    let path = rawPath.removingPercentEncoding ?? rawPath
    var page: Int? = nil
    if parts.count > 1,
      let match = parts[1].range(of: #"^page=(\d+)$"#, options: .regularExpression)
    {
      page = Int(parts[1][match].dropFirst(5))
    }
    return MarkdownFileLink(path: path, page: page)
  }

  /// 解析为磁盘上真实存在的文件 URL（md 目录优先，工作区根目录回退）；均不存在返回 nil
  static func resolve(path: String, documentDir: URL?, workspaceRoot: URL?) -> URL? {
    let fileManager = FileManager.default
    if path.hasPrefix("/") {
      let url = URL(fileURLWithPath: path)
      return fileManager.fileExists(atPath: url.path) ? url : nil
    }
    var candidates: [URL] = []
    if let documentDir {
      candidates.append(documentDir.appendingPathComponent(path).standardizedFileURL)
    }
    if let workspaceRoot {
      candidates.append(workspaceRoot.appendingPathComponent(path).standardizedFileURL)
    }
    return candidates.first { fileManager.fileExists(atPath: $0.path) }
  }
}
