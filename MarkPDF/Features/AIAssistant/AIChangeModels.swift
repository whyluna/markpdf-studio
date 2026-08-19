import Foundation

/// AI 写作提案模型（FR-AI.5）：agent 循环中写工具产出、排队等待用户审查的变更。
/// 提案只是意图快照——循环内绝不落盘；应用时刻由 AIChangeApplier 对当前文本重新校验
///（提案后用户手改文件只冲突对应块，不整批失败）。
struct AIChangeSet: Identifiable, Equatable, Codable {
  /// var：id 必须随 Codable 往返（let+默认值会被合成编码排除，重启后卡片引用失配）
  var id: UUID = UUID()
  var changes: [AIFileChange] = []

  var isEmpty: Bool { changes.isEmpty }
}

/// 单文件变更提案。同一文件同一类变更在入队时合并（editFile 追加块，新建后提覆盖先提）
struct AIFileChange: Identifiable, Equatable, Codable {
  /// var：理由同 AIChangeSet.id（reviews 按 file id 键控，重启恢复须同 id）
  var id: UUID = UUID()
  var kind: Kind
  /// 工作区相对路径（POSIX 斜杠；入队前已过防逃逸校验）
  var path: String
  /// 新建文件的完整内容（kind == .createFile）
  var content: String
  /// 搜索替换块（kind == .editFile）；按序应用，oldText 须在应用时刻的文本中唯一
  var edits: [TextEdit]

  enum Kind: String, Equatable, Codable {
    case createFile
    case editFile
    case createFolder
  }

  struct TextEdit: Equatable, Codable {
    var oldText: String
    var newText: String
  }
}

/// 搜索替换块应用引擎（纯函数，Aider SEARCH/REPLACE 范式）：
/// 逐条顺序应用，每条的 oldText 在「前序编辑应用后的文本」中查找；
/// 单条失败（未命中/多义/空 oldText）记录原因并跳过，不中断后续条目。
enum AIEditApplication {
  enum EditError: Equatable {
    case emptyOldText
    case notFound
    case ambiguous(count: Int)

    var guidance: String {
      switch self {
      case .emptyOldText: return "old_text is empty"
      case .notFound: return "old_text not found — it must match the file exactly, including whitespace and indentation"
      case .ambiguous(let count): return "old_text matches \(count) places — extend it with surrounding context to make it unique"
      }
    }
  }

  struct Outcome: Equatable {
    var text: String
    var appliedIndices: Set<Int> = []
    /// 失败条目：下标 → 原因
    var failures: [Int: EditError] = [:]

    var appliedCount: Int { appliedIndices.count }
    var skippedCount: Int { failures.count }
  }

  /// 应用一组编辑；skipping 中的下标不应用（审查阶段逐块勾选用）
  static func apply(
    _ edits: [AIFileChange.TextEdit],
    to text: String,
    replaceAll: Bool = false,
    skipping: Set<Int> = []
  ) -> Outcome {
    var working = text
    var outcome = Outcome(text: working)
    for (index, edit) in edits.enumerated() {
      guard !skipping.contains(index) else { continue }
      guard !edit.oldText.isEmpty else {
        outcome.failures[index] = .emptyOldText
        continue
      }
      let matches = working.ranges(of: edit.oldText)
      switch matches.count {
      case 0:
        outcome.failures[index] = .notFound
      case 1:
        if let range = matches.first {
          working.replaceSubrange(range, with: edit.newText)
          outcome.appliedIndices.insert(index)
        }
      default:
        if replaceAll {
          working = working.replacingOccurrences(of: edit.oldText, with: edit.newText)
          outcome.appliedIndices.insert(index)
        } else {
          outcome.failures[index] = .ambiguous(count: matches.count)
        }
      }
    }
    outcome.text = working
    return outcome
  }
}
