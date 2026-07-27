import Foundation
import NaturalLanguage

/// 工作区检索（FR-AI.2 第三层上下文，v1.2）：问题分词取关键词 →
/// FullTextSearch 逐词召回 → 按文件聚合取 top 命中。无 embedding。
enum AIWorkspaceRetriever {
  /// 注入的命中上限（snippet 短，预算占用小）
  static let maxHits = 3
  /// 提取的检索关键词上限
  static let maxKeywords = 6

  /// 问题 → 检索关键词（NLTokenizer 中英分词；长度 ≥2 去重，保持出现顺序）
  static func keywords(from question: String, limit: Int = maxKeywords) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = question
    var seen = Set<String>()
    var result: [String] = []
    tokenizer.enumerateTokens(in: question.startIndex..<question.endIndex) { range, _ in
      let token = String(question[range])
      if token.count >= 2, seen.insert(token.lowercased()).inserted {
        result.append(token)
      }
      return result.count < limit
    }
    return result
  }

  /// 同步召回（调用方后台执行）：逐关键词搜索 → 按文件聚合最高分命中 → top N。
  /// 排除当前文档（其内容已由第二层注入）
  static func retrieve(question: String, files: [URL], excluding currentDoc: URL?) -> [AIContextBuilder.WorkspaceHit] {
    let words = keywords(from: question)
    guard !words.isEmpty else { return [] }
    let candidates = files.filter { $0 != currentDoc }
    guard !candidates.isEmpty else { return [] }

    // 文件路径 → 最佳命中（分数累加：多词命中的文件更相关）
    var best: [URL: (score: Int, result: FullTextSearchResult)] = [:]
    for word in words {
      for hit in FullTextSearch.search(query: word, files: candidates, isCancelled: { false }) {
        if var entry = best[hit.url] {
          entry.score += hit.score
          best[hit.url] = entry
        } else {
          best[hit.url] = (hit.score, hit)
        }
      }
    }
    return best.values
      .sorted { $0.score > $1.score }
      .prefix(maxHits)
      .map { entry in
        AIContextBuilder.WorkspaceHit(
          file: entry.result.url.lastPathComponent,
          anchor: entry.result.kind == .pdf ? "p.\(entry.result.location)" : "L\(entry.result.location)",
          snippet: entry.result.snippet
        )
      }
  }
}
