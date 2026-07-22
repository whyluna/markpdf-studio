import Foundation

/// 拼音首字母（FR-6.3 命令面板）：中文取各字拼音首字母，拉丁词取词首。
/// 用系统 CFStringTransform 转拉丁（含声调）再去声调，无需内置拼音表。
enum PinyinInitials {
  /// 返回小写首字母串：「导出全部标注为 Markdown」→ "dcqbbzwm"
  static func of(_ text: String) -> String {
    let mutable = NSMutableString(string: text)
    // 转拉丁（中文 → 带声调拼音，各字以空格分隔）
    guard CFStringTransform(mutable, nil, kCFStringTransformToLatin, false),
      CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    else { return "" }
    return mutable
      .components(separatedBy: .whitespaces)
      .compactMap { $0.first?.lowercased() }
      .joined()
  }
}
