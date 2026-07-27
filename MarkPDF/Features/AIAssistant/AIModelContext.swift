import Foundation

/// 模型上下文窗口估算（FR-AI.2 v1.2：上下文动态预算）。
/// 按模型名关键字推断（内置 Provider 常见模型族）；未知模型取保守值。
/// 换算口径：中文 1 token ≈ 1 字（英文实际更省 token，按中文估算恒安全）
enum AIModelContext {
  /// 未知模型的保守上下文（tokens）
  static let conservativeTokens = 32_000
  /// 文档字符预算下限（再小的窗口也保底给文档留这些字符）
  static let minDocumentChars = 4_000
  /// 文档字符预算上限（超大窗口不必无限膨胀：单篇论文 15 万字符已远超覆盖）
  static let maxDocumentChars = 150_000
  /// 预留 tokens：回复 maxTokens 4096 + system/历史/选区/问题 ≈ 4000
  static let reservedTokens = 8_000

  /// 按模型名估算上下文窗口（tokens）
  static func estimatedTokens(forModel model: String) -> Int {
    let name = model.lowercased()
    // 后缀显式标注优先（moonshot-v1-8k / -32k / -128k 等）
    if name.contains("-8k") { return 8_000 }
    if name.contains("-32k") { return 32_000 }
    if name.contains("-128k") { return 128_000 }
    if name.contains("gemini") { return 1_000_000 }
    if name.contains("claude") { return 200_000 }
    if name.contains("kimi") || name.contains("moonshot") { return 128_000 }
    if name.contains("deepseek") { return 64_000 }
    if name.contains("gpt-4o") || name.contains("gpt-4.1") || name.contains("gpt-5")
      || name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
      return 128_000
    }
    if name.contains("qwen") { return 128_000 }
    return conservativeTokens
  }

  /// 当前文档的字符预算：窗口减预留后按 1 token ≈ 1 字符换算，夹取上下限。
  /// 装得下整文喂入（单篇论文 QA 实证优于 RAG）；超预算由结构选节降级（D3）
  static func documentCharBudget(forModel model: String) -> Int {
    let available = estimatedTokens(forModel: model) - reservedTokens
    return min(max(available, minDocumentChars), maxDocumentChars)
  }
}
