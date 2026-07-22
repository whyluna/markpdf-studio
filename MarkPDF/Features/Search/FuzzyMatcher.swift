import Foundation

/// 模糊匹配结果（FR-6.1）
struct FuzzyMatch: Equatable {
  /// 评分（越高越好）
  let score: Int
  /// 命中字符下标（候选串内，供高亮）
  let positions: [Int]
}

/// 预处理后的模糊查询（FR-6.1）：正规化（小写化 + 字符化）只做一次，
/// 供批量候选匹配复用——此前每个候选都重复 `Array(query.lowercased())`
struct FuzzyQuery {
  /// 已小写化的查询字符序列
  let characters: [Character]

  init(_ query: String) {
    characters = Array(query.lowercased())
  }

  var isEmpty: Bool { characters.isEmpty }
}

/// 文件名模糊匹配（FR-6.1）：子序列匹配 + 评分。
/// 纯函数（开发规范 §7 可单测）；评分偏好连续命中、词首命中与短候选。
enum FuzzyMatcher {
  /// 预处理查询：批量匹配前先调用一次，各候选复用同一结果
  static func prepare(_ query: String) -> FuzzyQuery {
    FuzzyQuery(query)
  }

  /// 匹配成功返回结果，失败返回 nil；空查询匹配一切（score 0）
  static func match(_ query: FuzzyQuery, in candidate: String) -> FuzzyMatch? {
    if query.isEmpty { return FuzzyMatch(score: 0, positions: []) }
    let q = query.characters
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
