import Foundation

/// 模糊匹配结果（FR-6.1）
struct FuzzyMatch: Equatable {
  /// 评分（越高越好）
  let score: Int
  /// 命中字符下标（候选串内，供高亮）
  let positions: [Int]
}

/// 文件名模糊匹配（FR-6.1）：子序列匹配 + 评分。
/// 纯函数（开发规范 §7 可单测）；评分偏好连续命中、词首命中与短候选。
enum FuzzyMatcher {
  /// 匹配成功返回结果，失败返回 nil；空查询匹配一切（score 0）
  static func match(query: String, in candidate: String) -> FuzzyMatch? {
    if query.isEmpty { return FuzzyMatch(score: 0, positions: []) }
    let q = Array(query.lowercased())
    let c = Array(candidate.lowercased())
    var positions: [Int] = []
    positions.reserveCapacity(q.count)
    var score = 0
    var qi = 0
    var lastHit = -2
    for (ci, ch) in c.enumerated() where qi < q.count {
      guard ch == q[qi] else { continue }
      positions.append(ci)
      score += 1
      if ci == lastHit + 1 { score += 3 } // 连续命中
      if ci == 0 || isBoundary(c[ci - 1]) { score += 2 } // 词首命中
      lastHit = ci
      qi += 1
    }
    guard qi == q.count else { return nil }
    score -= c.count / 8 // 短候选优先
    return FuzzyMatch(score: score, positions: positions)
  }

  private static func isBoundary(_ ch: Character) -> Bool {
    ch == " " || ch == "-" || ch == "_" || ch == "/" || ch == "."
  }
}
