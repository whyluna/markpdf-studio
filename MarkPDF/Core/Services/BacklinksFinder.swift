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

  /// 先 stat 再读盘（与全文搜索 PDF 路径口径一致）：超限文件不整读进内存
  static func isWithinSizeLimit(_ file: URL) -> Bool {
    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    return size <= maxFileBytes
  }

  /// 逐文件检查 isCancelled，返回 true 即中止并返回已收集结果（取消后调用方本就丢弃，
  /// 提前退出只是不再把剩余 md 全部读完——保存风暴下取消的旧任务立即释放 IO）。
  static func find(
    target: URL,
    in mdFiles: [URL],
    workspaceRoot: URL?,
    isCancelled: () -> Bool = { false }
  ) -> [Backlink] {
    // dest 二选一：CommonMark 角标形式 `<...>`（允许含空格）或无角标形式
    //（遇空白停止；括号须平衡——`报告(终稿).pdf` 是合法 dest，简单 `[^)]+` 会截断漏配）
    let pattern = #"\[([^\]]*)\]\(\s*(<[^>]+>|(?:[^()\s>]|\([^()\s>]*\))+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let normalizedTarget = target.standardizedFileURL
    let targetName = target.lastPathComponent
    var result: [Backlink] = []
    for file in mdFiles {
      if isCancelled() { break }
      // 先判大小再读盘：超限文件（GB 级日志混入工作区）不应整读进内存后才丢弃
      guard file.standardizedFileURL != normalizedTarget,
        Self.isWithinSizeLimit(file),
        let data = try? Data(contentsOf: file),
        let content = String(data: data, encoding: .utf8)
      else { continue }
      // 预筛：不含目标文件名的直接跳过（大工作区下避免全文正则 + 逐链接 resolve 的 syscall 开销）。
      // App 自产回链会把空格等字符 percent 编码（%20）写入 md，原文与编码变体任一命中即放行；
      // 大小写不敏感与 APFS 默认行为一致（[x](Note.MD) 指向 note.md 不应被漏掉）。
      let targetNameEncoded =
        targetName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? targetName
      guard [targetName, targetNameEncoded].contains(where: {
        content.range(of: $0, options: .caseInsensitive) != nil
      })
      else { continue }
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
        var dest = String(content[destRange])
        // 角标形式 <dest> 剥离角标后再解析（无角标 dest 不含 < >，不受影响）
        if dest.hasPrefix("<"), dest.hasSuffix(">") {
          dest = String(dest.dropFirst().dropLast())
        }
        guard let link = MarkdownFileLink.parse(dest),
          let resolved = MarkdownFileLink.resolve(
            path: link.path,
            documentDir: file.deletingLastPathComponent(),
            workspaceRoot: workspaceRoot
          ),
          // APFS 默认大小写不敏感，终比对按路径忽略大小写（Note.MD 与 note.md 是同一文件）
          resolved.standardizedFileURL.path.caseInsensitiveCompare(normalizedTarget.path)
            == .orderedSame
        else { continue }
        let text = String(content[textRange])
        result.append(Backlink(source: file, text: text.isEmpty ? file.lastPathComponent : text))
      }
    }
    return result.sorted { $0.source.path < $1.source.path }
  }
}
