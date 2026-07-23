import Foundation

/// 翻译源文本整理（FR-AI.1 体验修复）：PDF 按物理行提取文本，
/// 直接送译会把断词（informa-\ntion）切碎、译文也会镜像源文本的乱换行。
/// 整理为整句：去行尾连字符、物理换行合并为空格、折叠空白。
enum TranslationTextNormalizer {
  /// 整理 PDF 提取文本（翻译输入与气泡展示共用同一口径）
  static func normalize(_ text: String) -> String {
    var result = text
    // 拉丁断词：行尾连字符 + 换行 → 直接相连（informa-\ntion → information）
    result = result.replacingOccurrences(
      of: #"-\s*\n\s*"#, with: "", options: .regularExpression
    )
    // 剩余物理换行 → 空格（PDF 的换行不是语义分段）
    result = result.replacingOccurrences(
      of: #"\s*\n\s*"#, with: " ", options: .regularExpression
    )
    // 折叠连续空格
    result = result.replacingOccurrences(
      of: #" {2,}"#, with: " ", options: .regularExpression
    )
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
