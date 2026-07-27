import Foundation

/// 上下文预算（FR-AI.2 v1.3）：窗口与回复上限均以用户设定为准，不做模型名猜测。
/// suggestedTokens 仅用于新增模型时预填建议值（用户可改）。
/// 换算口径：中文 1 token ≈ 1 字（英文实际更省 token，按中文估算恒安全）
enum AIModelContext {
  /// 新增模型时的预填建议窗口（tokens）；未识别取保守值
  static let conservativeTokens = 32_000
  /// 文档字符预算下限（再小的窗口也保底给文档留这些字符）
  static let minDocumentChars = 2_000
  /// 文档字符预算上限（超大窗口不必无限膨胀：单篇论文 15 万字符已远超覆盖）
  static let maxDocumentChars = 150_000
  /// system 提示 + 工具 schema + 选区 + 问题的预留（tokens）
  static let overheadTokens = 5_000
  /// 历史区字符预算上限
  static let maxHistoryChars = 24_000
  /// 用户设定的回复上限异常时（≥窗口）夹取到窗口的比例
  static let replyClampRatio = 2

  /// 按模型名预填建议窗口（仅新增模型时的默认值，用户可改、以用户值为准）
  static func suggestedTokens(forModel model: String) -> Int {
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

  /// 回复上限收口：用户设定 ≥ 窗口时夹到窗口一半（输入输出共享窗口，回复占满即无输入空间）
  static func effectiveReplyTokens(userSetting: Int, contextTokens: Int) -> Int {
    guard userSetting > 0 else { return contextTokens / replyClampRatio }
    return userSetting >= contextTokens ? contextTokens / replyClampRatio : userSetting
  }

  /// 历史区字符预算：窗口的 20%，封顶 maxHistoryChars
  static func historyCharBudget(contextTokens: Int) -> Int {
    min(contextTokens / 5, maxHistoryChars)
  }

  /// 当前文档字符预算 = 窗口 − 回复 − 历史 − 固定预留，夹取 [min, max]。
  /// 装得下整文喂入（单篇论文 QA 实证优于 RAG）；超预算由结构选节降级
  static func documentCharBudget(contextTokens: Int, replyTokens: Int) -> Int {
    let reply = effectiveReplyTokens(userSetting: replyTokens, contextTokens: contextTokens)
    let available = contextTokens - reply - historyCharBudget(contextTokens: contextTokens) - overheadTokens
    return min(max(available, minDocumentChars), maxDocumentChars)
  }
}
