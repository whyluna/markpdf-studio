import Foundation

/// AI 助手上下文装配（FR-AI.2）：纯函数，不触 UI/网络。
/// 上下文只嵌当轮 user 消息（历史轮仅存原始问题）——控 token 预算，
/// 且避免 Anthropic 构造器把多条 system 合并后各轮上下文串轮。
enum AIContextBuilder {
  /// 选区预算（与划词翻译 TranslationStore.maxAIInputCharacters 同口径）
  static let selectionBudget = 2_000
  /// 当前文档预算保守回退值（v1.2 起按模型动态计算，见 AIModelContext.documentCharBudget；
  /// 此常量仅作未传参时的回退与测试基准）
  static let documentBudget = 8_000
  /// L1 工作记忆：送出的历史消息条数上限（8 轮 user+assistant；更早并入滚动摘要）
  static let historyMessageCap = 16
  /// 滚动摘要压缩请求的回复预算（v1.4 按压缩比）：输入的 ~30%，
  /// 字符→token 粗换 ÷2 保守，夹取 [512, 4096]（压 2 万字给 ~3000tk，小输入保底 512）
  static func compactionMaxTokens(forInputChars chars: Int) -> Int {
    min(max(chars * 3 / 20, 512), 4_096)
  }
  /// 摘要注入区占历史预算的比例分子/分母（30%；其余 70% 给近期原文保留区）
  static let summaryInjectionRatio = (numerator: 3, denominator: 10)

  struct BuiltContext: Equatable {
    /// 组装后的当轮 user 消息（标签块 + 问题）
    let userMessage: String
    /// 附带内容摘要（气泡下小字，如「选区 320 字 · 当前文档（截断）」）；无上下文为 nil
    let summary: String?
  }

  /// 固定人设（模型输入，英文写死不进 catalog；说明标签块/锚点/截断约定）
  static func systemPrompt() -> String {
    """
    You are a helpful assistant embedded in MarkPDF Studio, a Markdown + PDF reading and writing tool. \
    The user's question may include context blocks labeled [Selection] (text the user selected) and \
    [Document: name] (the current document, possibly truncated or reduced to selected sections). \
    Sections may be prefixed with anchors like [§Title] or [p.5]; when your answer relies on a section, \
    cite its anchor inline. Base document-related answers only on the provided context and tool results; \
    say so plainly when they are insufficient. \
    Answer in the language the user writes in. Prefer concise Markdown.
    """
  }

  /// 组装当轮 user 消息：`[Selection]`/`[Document: xxx]` 标签块 + `[Question]`。
  /// documentBudget 按所选模型动态传入（AIModelContext.documentCharBudget）
  static func buildUserMessage(
    question: String,
    selection: String?,
    document: (name: String, text: String)?,
    documentBudget: Int = AIContextBuilder.documentBudget,
    documentAnnotation: String? = nil
  ) -> BuiltContext {
    var blocks: [String] = []
    var summaryParts: [String] = []

    if let selection, !selection.isEmpty {
      let clipped = String(selection.prefix(selectionBudget))
      let truncated = clipped.count < selection.count
      blocks.append("[Selection]\n\(clipped)\(truncated ? "\n…(truncated)" : "")")
      summaryParts.append(
        truncated
          ? String(localized: "选中文字 \(clipped.count) 字（截断）")
          : String(localized: "选中文字 \(clipped.count) 字")
      )
    }
    if let document, !document.text.isEmpty {
      let clipped = String(document.text.prefix(max(documentBudget, 0)))
      let truncated = clipped.count < document.text.count
      blocks.append("[Document: \(document.name)]\n\(clipped)\(truncated ? "\n…(truncated)" : "")")
      if let documentAnnotation {
        summaryParts.append(String(localized: "文档 \(document.name)（\(documentAnnotation)）"))
      } else if truncated {
        summaryParts.append(String(localized: "文档 \(document.name)（截断）"))
      } else {
        summaryParts.append(String(localized: "文档 \(document.name)"))
      }
    }
    blocks.append(blocks.isEmpty ? question : "[Question]\n\(question)")
    return BuiltContext(
      userMessage: blocks.joined(separator: "\n\n"),
      summary: summaryParts.isEmpty ? nil : summaryParts.joined(separator: " · ")
    )
  }

  /// 历史裁剪：掐头留尾（最近 historyMessageCap 条）+ 丢弃空 assistant
  /// （取消时的零增量消息会让 Anthropic 报非空校验 400）
  static func trimHistory(_ messages: [AIChatMessage]) -> [AIChatMessage] {
    let nonEmpty = messages.filter { !($0.role == .assistant && $0.content.isEmpty) }
    return Array(nonEmpty.suffix(historyMessageCap))
  }

  /// 保留区分割（v1.4，供压缩与历史组装共用防两处漂移）：从尾部累计字符 ≤ preserveChars
  /// 的最近消息，分割点对齐轮次边界（preserved 首条必须是 user——不劈开一轮）；
  /// 全装得下时 toCompact 为空；单轮超长时保底保留最后一轮完整原文
  static func splitForPreservation(
    _ messages: [AIChatMessage],
    preserveChars: Int
  ) -> (toCompact: [AIChatMessage], preserved: [AIChatMessage]) {
    guard !messages.isEmpty else { return ([], []) }
    var total = 0
    var splitIndex: Int?
    for index in messages.indices.reversed() {
      total += messages[index].content.count
      guard messages[index].role == .user, index == 0 || messages[index - 1].role != .user else { continue }
      if total <= preserveChars {
        splitIndex = index  // 继续向前尝试容纳更早的轮次
      } else {
        if splitIndex == nil { splitIndex = index }  // 单轮超长保底：至少保留最后一轮
        break
      }
    }
    let split = splitIndex ?? 0
    return (Array(messages[..<split]), Array(messages[split...]))
  }

  /// 历史区组装（v1.3 三层）：L2 滚动摘要首条注入（配 assistant 占位保交替，
  /// 注入区限历史预算 30%，超长截断）+ L1 最近原文（条数 cap + 字符预算按轮次边界掐头）
  static func historyMessages(
    _ messages: [AIChatMessage],
    rollingSummary: String?,
    charBudget: Int
  ) -> [AIChatMessage] {
    let recent = trimHistory(messages)
    let kept = splitForPreservation(recent, preserveChars: charBudget).preserved
    guard let rollingSummary, !rollingSummary.isEmpty else { return kept }
    let summaryCap = charBudget * summaryInjectionRatio.numerator / summaryInjectionRatio.denominator
    let clipped = rollingSummary.count > summaryCap
      ? String(rollingSummary.prefix(summaryCap)) + "\n…(truncated)"
      : rollingSummary
    return [
      .user("[Earlier conversation summary]\n\(clipped)"),
      .assistant("OK."),
    ] + kept
  }

  /// 压缩请求（后台异步；输入 = 旧摘要 + 待压缩轮次原文，输出新摘要整体替换）
  static func compactionMessages(existingSummary: String?, turns: [AIChatMessage]) -> [AIChatMessage] {
    let transcript = turns.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
    let previous = existingSummary.map { "Previous summary:\n\($0)\n\n" } ?? ""
    return [
      .system("""
        Compress the following conversation into a summary. Make its length proportionate to \
        the input and keep it dense — do not over-shorten long conversations. \
        Keep conclusions, cited anchors like [§Title]/[p.N], unresolved questions, and user preferences. \
        Merge with the previous summary if given. Reply with the summary only.
        """),
      .user(previous + "Conversation:\n" + transcript),
    ]
  }
}
