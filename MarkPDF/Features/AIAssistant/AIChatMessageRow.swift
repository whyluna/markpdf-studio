import SwiftUI

/// AI 助手回复的编辑器动作条（FR-AI.2 五动作）：由面板组装闭包，流式中整体禁用
struct AIMessageActions {
  var canInsert: () -> Bool = { false }
  var insertAtCursor: (String) -> Void = { _ in }
  var replaceSelection: (String) -> Void = { _ in }
  var canSaveNote: () -> Bool = { false }
  var saveAsNote: (String) -> Void = { _ in }
  var canQuote: () -> Bool = { false }
  var copyAsQuote: (String) -> Void = { _ in }
}

/// 单条消息行：user 右对齐气泡 + 上下文摘要；assistant 渲染 + 动作条 + 流式指示
struct AIChatMessageRow: View {
  let message: AIChatStore.ChatMessage
  let isBusy: Bool
  let actions: AIMessageActions
  @State private var isHovering = false

  var body: some View {
    switch message.role {
    case .user:
      userRow
    default:
      assistantRow
    }
  }

  private var userRow: some View {
    VStack(alignment: .trailing, spacing: 3) {
      Text(message.content)
        .font(.body)
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
      if let summary = message.contextSummary {
        Text("已附带：\(summary)")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var assistantRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      AIMessageTextView(markdown: message.content)
      HStack(spacing: 10) {
        if message.isStreaming {
          ProgressView()
            .controlSize(.mini)
        }
        if message.wasCancelled {
          Text("已停止")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        if !message.isStreaming, !message.content.isEmpty, isHovering, !isBusy {
          actionBar
        }
      }
      .frame(height: 18)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onHover { isHovering = $0 }
  }

  /// 五动作（FR-AI.2）：插入光标 / 替换选区 / 复制 / 存为新笔记 / 转回链引用块
  private var actionBar: some View {
    HStack(spacing: 8) {
      actionButton("text.insert", help: String(localized: "插入到光标处")) {
        actions.insertAtCursor(message.content)
      }
      .disabled(!actions.canInsert())
      actionButton("arrow.2.squarepath", help: String(localized: "替换编辑器选区")) {
        actions.replaceSelection(message.content)
      }
      .disabled(!actions.canInsert())
      actionButton("doc.on.doc", help: String(localized: "复制回复")) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
      }
      actionButton("square.and.pencil", help: String(localized: "存为新笔记")) {
        actions.saveAsNote(message.content)
      }
      .disabled(!actions.canSaveNote())
      actionButton("quote.opening", help: String(localized: "复制为带回链的引用（当前页）")) {
        actions.copyAsQuote(message.content)
      }
      .disabled(!actions.canQuote())
    }
  }

  private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

#Preview {
  VStack(spacing: 16) {
    AIChatMessageRow(
      message: {
        var m = AIChatStore.ChatMessage(role: .user, content: "总结这段的核心论点")
        m.contextSummary = "选区 320 字 · 文档 paper.pdf"
        return m
      }(),
      isBusy: false,
      actions: AIMessageActions()
    )
    AIChatMessageRow(
      message: AIChatStore.ChatMessage(role: .assistant, content: "核心论点是 **注意力机制** 可以替代循环结构。"),
      isBusy: false,
      actions: AIMessageActions()
    )
  }
  .padding()
  .frame(width: 320)
}
