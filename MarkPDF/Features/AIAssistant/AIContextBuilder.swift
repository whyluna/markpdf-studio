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
  /// 送出的历史消息条数上限（12 轮 user+assistant）
  static let historyMessageCap = 24

  struct BuiltContext: Equatable {
    /// 组装后的当轮 user 消息（标签块 + 问题）
    let userMessage: String
    /// 附带内容摘要（气泡下小字，如「选区 320 字 · 当前文档（截断）」）；无上下文为 nil
    let summary: String?
  }

  /// 固定人设（模型输入，英文写死不进 catalog；说明标签块与截断约定）
  static func systemPrompt() -> String {
    """
    You are a helpful assistant embedded in MarkPDF Studio, a Markdown + PDF reading and writing tool. \
    The user's question may include context blocks labeled [Selection] (text the user selected) and \
    [Document: name] (the current document, possibly truncated). Use them when relevant. \
    Answer in the language the user writes in. Prefer concise Markdown.
    """
  }

  /// 组装当轮 user 消息：`[Selection]`/`[Document: xxx]` 标签块 + `[Question]`。
  /// documentBudget 按所选模型动态传入（AIModelContext.documentCharBudget）
  static func buildUserMessage(
    question: String,
    selection: String?,
    document: (name: String, text: String)?,
    documentBudget: Int = AIContextBuilder.documentBudget
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
      summaryParts.append(
        truncated
          ? String(localized: "文档 \(document.name)（截断）")
          : String(localized: "文档 \(document.name)")
      )
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
}
