import Foundation
import NaturalLanguage
import PDFKit

/// 工作区检索（FR-AI.2 第三层上下文，v1.2 完整形态）：
/// 问题分词 → FullTextSearch 召回命中文件 → 每文件结构切节为候选 →
/// 候选多时经 LLM 目录选节（AIChatStore 调用路由），选中节全文注入。无 embedding。
enum AIWorkspaceRetriever {
  /// 参与切节的命中文件上限
  static let maxFiles = 3
  /// 目录摘要的候选节总量上限（防超大文档目录爆炸）
  static let maxCandidateSections = 60
  /// 单文件候选节上限
  static let maxSectionsPerFile = 30
  /// 直接全注入（免路由）的候选节数阈值
  static let directInjectThreshold = 4
  /// 注入的节数上限（路由选出）
  static let maxPickedSections = 4
  /// 工作区块总字符预算
  static let totalBudget = 16_000
  /// 提取的检索关键词上限
  static let maxKeywords = 6

  /// 候选节：来源文件 + 该文件内的一节
  struct Candidate: Equatable {
    let file: String
    let section: DocumentSection
  }

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

  /// 同步召回并切节（调用方后台执行）：逐关键词搜索 → 文件按累计分数排序取前
  /// maxFiles 个 → 每文件切节（md 读盘文本 / PDF 自建文档按书签）。排除当前文档
  static func candidateSections(question: String, files: [URL], excluding currentDoc: URL?) -> [Candidate] {
    let words = keywords(from: question)
    guard !words.isEmpty else { return [] }
    let searchable = files.filter { $0 != currentDoc }
    guard !searchable.isEmpty else { return [] }

    // 一次遍历多词合并计分（此前逐词各扫一遍全工作区：6 词 = 6 倍读盘/解析）
    var scores: [URL: Int] = [:]
    for url in searchable {
      let score = FullTextSearch.multiTermScore(url: url, terms: words)
      if score > 0 { scores[url] = score }
    }
    let topFiles = scores.sorted { $0.value > $1.value }.prefix(maxFiles).map(\.key)

    var candidates: [Candidate] = []
    for url in topFiles {
      // 切节走懒缓存（key=路径+mtime+大小；同文件连续提问不重复解析）
      let sections = DocumentSectionCache.shared.sections(for: url) {
        switch FileNode.kind(for: url, isDirectory: false) {
        case .markdown:
          guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
          return DocumentSectioner.fromMarkdown(text)
        case .pdf:
          guard let document = PDFDocument(url: url) else { return nil }
          return DocumentSectioner.fromPDF(document)
        default:
          return nil
        }
      } ?? []
      for section in sections.prefix(maxSectionsPerFile) where !section.text.isEmpty {
        candidates.append(Candidate(file: url.lastPathComponent, section: section))
      }
      if candidates.count >= maxCandidateSections { break }
    }
    return Array(candidates.prefix(maxCandidateSections))
  }

  /// 候选目录摘要（路由第一遍输入）：编号 + 文件 + 锚点 + 标题 + 首句
  static func routingOutline(_ candidates: [Candidate], leadChars: Int = 60) -> String {
    candidates.enumerated().map { index, candidate in
      let lead = candidate.section.text.prefix(leadChars).replacingOccurrences(of: "\n", with: " ")
      return "\(index). [\(candidate.file) \(candidate.section.anchor)] \(candidate.section.title) — \(lead)"
    }.joined(separator: "\n")
  }

  /// 选中节 → 注入块（每节按预算份额截断；file+anchor 供锚点引用）
  static func assembleHits(candidates: [Candidate], picked: [Int]) -> [AIContextBuilder.WorkspaceHit] {
    let valid = picked.filter { candidates.indices.contains($0) }.prefix(maxPickedSections)
    guard !valid.isEmpty else { return [] }
    let perHit = totalBudget / valid.count
    return valid.map { index in
      let candidate = candidates[index]
      return AIContextBuilder.WorkspaceHit(
        file: candidate.file,
        anchor: candidate.section.anchor,
        snippet: String(candidate.section.text.prefix(perHit))
      )
    }
  }

  /// 路由失败/解析不出时的回退：取前 3 个候选节各截 300 字
  static func fallbackHits(candidates: [Candidate]) -> [AIContextBuilder.WorkspaceHit] {
    candidates.prefix(3).map {
      AIContextBuilder.WorkspaceHit(
        file: $0.file,
        anchor: $0.section.anchor,
        snippet: String($0.section.text.prefix(300))
      )
    }
  }
}
