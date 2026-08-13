import Foundation

/// 阅读位置所属小节的定位（PDF 目录 / md 大纲共用，纯函数可单测）
enum ActiveSection {
  /// 最后一个位置 ≤ current 的条目下标；全部条目都在 current 之后为 nil
  ///（positions 为各小节的起始页/起始行，按文档顺序；current 为当前页/当前行，均 1 起）
  static func index(positions: [Int], current: Int) -> Int? {
    var result: Int?
    for (index, position) in positions.enumerated() where position <= current {
      result = index
    }
    return result
  }
}
