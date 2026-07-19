import Foundation

/// 文本统计（FR-2.8）：字数 / 字符数 / 预计阅读时长（纯值类型，Core/Models 规范）。
/// 口径（对齐 Typora）：CJK 字符逐字计、西文按词计合成「字数」；字符数不含空白。
struct EditorStats: Equatable {
  /// 字数：CJK 逐字 + 西文单词
  let words: Int
  /// 字符数（不含空白与换行）
  let characters: Int
  /// 预计阅读时长（分钟；按 400 字/分钟，非空至少 1 分钟）
  let readingMinutes: Int
}

enum TextStatistics {
  /// 阅读速度（字/分钟，中文常规速读）
  static let wordsPerMinute = 400

  static func of(_ text: String) -> EditorStats {
    var words = 0
    var characters = 0
    var inLatinWord = false
    for scalar in text.unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        inLatinWord = false
        continue
      }
      characters += 1
      if isCJK(scalar) {
        words += 1
        inLatinWord = false
      } else if !inLatinWord {
        words += 1
        inLatinWord = true
      }
    }
    let minutes = words == 0 ? 0 : max(1, Int(ceil(Double(words) / Double(wordsPerMinute))))
    return EditorStats(words: words, characters: characters, readingMinutes: minutes)
  }

  /// CJK 表意文字、日文假名、韩文音节、CJK 标点与全角字符（这些按「字」逐字计）
  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3000...0x303F,  // CJK 标点
      0x3040...0x30FF,  // 平/片假名
      0x3400...0x4DBF,  // 扩展 A
      0x4E00...0x9FFF,  // 基本表意
      0xAC00...0xD7AF,  // 韩文音节
      0xF900...0xFAFF,  // 兼容表意
      0xFF00...0xFFEF:  // 全角字符
      return true
    default:
      return false
    }
  }
}
