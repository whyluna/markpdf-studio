import Foundation

/// 两遍路由的第一遍（FR-AI.2 v1.2）：把「问题 + 目录摘要」给模型，让它选出
/// 回答所需的节编号。纯 prompt 构造与应答解析（网络调用在 AIChatStore）。
enum AISectionRouter {
  /// 路由请求最大回复（只要一个 JSON 数组）
  static let maxTokens = 128
  /// 最多选出的节数
  static let maxPicked = 6

  /// 路由指令（模型输入，英文写死）
  static func routingMessages(question: String, outline: String) -> [AIChatMessage] {
    [
      .system("""
        You select which sections of a document are needed to answer a question. \
        Reply with ONLY a JSON array of section numbers (at most \(maxPicked)), \
        most relevant first, e.g. [2,0,5]. No other text.
        """),
      .user("Question:\n\(question)\n\nSections:\n\(outline)"),
    ]
  }

  /// 解析应答里的节编号数组；解析不出返回 nil（调用方回退头部截断）
  static func parsePicked(_ reply: String, sectionCount: Int) -> [Int]? {
    guard let start = reply.firstIndex(of: "["), let end = reply[start...].firstIndex(of: "]") else {
      return nil
    }
    let inner = reply[reply.index(after: start)..<end]
    let numbers = inner.split(separator: ",").compactMap {
      Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var seen = Set<Int>()
    let valid = numbers.filter { $0 >= 0 && $0 < sectionCount && seen.insert($0).inserted }
    return valid.isEmpty ? nil : Array(valid.prefix(maxPicked))
  }
}
