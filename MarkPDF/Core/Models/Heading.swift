import Foundation

/// Markdown 标题项（FR-2.6 大纲；纯值类型，开发规范 §2 Core/Models）
struct Heading: Identifiable, Equatable {
  /// 级别 1~6
  let level: Int
  /// 标题文本（已去 # 标记）
  let text: String
  /// 所在行号（1 起）
  let line: Int

  /// 行号在文档内唯一，作为标识
  var id: Int { line }
}
