import SwiftUI

/// 单条消息行：user 右对齐气泡 + 上下文摘要；assistant 渲染 + 变更卡片 + 复制 + 流式指示
///（原五动作中插入/替换/存笔记已由 AI 写作提案流取代，2026-08-19 用户决策只留复制）
struct AIChatMessageRow: View {
  let message: AIChatStore.ChatMessage
  let isBusy: Bool
  /// 写提案审查状态机（FR-AI.5 变更卡片渲染与操作）
  let changeStore: AIChangeStore
  @State private var isHovering = false
  @State private var copyFeedback = false

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
        .font(.system(size: 14))
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
      if !message.toolActivities.isEmpty {
        toolActivityChips
      }
      AIMessageTextView(markdown: message.content)
        .equatable()
      if let setID = message.changeSetID, let sealed = changeStore.changeSet(id: setID) {
        AIChangeCardView(sealed: sealed, store: changeStore, isBusy: isBusy)
      }
      if message.writingNoProposal {
        Label(writingNoProposalMessage, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .help(failedWriteActivity?.resultSummary ?? "")
      }
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
        // 复制按钮常驻（淡显），悬停变实—— hover 才出现时鼠标移向按钮的
        // 途中会穿过非悬停间隙，按钮在用户点击前消失（实测反馈）
        if !message.isStreaming, !message.content.isEmpty {
          copyButton
            .opacity(isHovering && !isBusy ? 1.0 : 0.35)
            .disabled(isBusy)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
      }
      .frame(height: 20)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }

  /// 工具活动 chips（v1.3 agent 循环）：运行中 spinner，完成后折叠为一行摘要
  private var toolActivityChips: some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach(message.toolActivities) { activity in
        HStack(spacing: 5) {
          if activity.isRunning {
            ProgressView()
              .controlSize(.mini)
          } else if activity.hasFailed {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 10))
              .foregroundStyle(.red)
          } else if activity.isPartialSuccess {
            Image(systemName: "exclamationmark.circle.fill")
              .font(.system(size: 10))
              .foregroundStyle(.orange)
          } else {
            Image(systemName: "checkmark.circle")
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
          Text(activityLabel(activity))
            .font(.caption)
            .foregroundStyle(activity.hasFailed ? Color.red : (activity.isPartialSuccess ? Color.orange : Color.secondary))
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .help(activity.resultSummary ?? "")
      }
    }
  }

  private func activityLabel(_ activity: AIChatStore.ToolActivity) -> String {
    let action: String
    switch activity.name {
    case "workspace_search": action = String(localized: "搜索工作区")
    case "workspace_list_documents": action = String(localized: "列出文档")
    case "workspace_get_outline": action = String(localized: "查看大纲")
    case "workspace_read_section": action = String(localized: "读取章节")
    case "workspace_write_file":
      action = activity.hasFailed ? String(localized: "新建提案失败") : String(localized: "提议新建文件")
    case "workspace_edit_file":
      if activity.hasFailed {
        action = String(localized: "修改提案失败")
      } else if activity.isPartialSuccess {
        action = String(localized: "提议部分修改")
      } else {
        action = String(localized: "提议修改文件")
      }
    case "workspace_create_folder":
      action = activity.hasFailed ? String(localized: "文件夹提案失败") : String(localized: "提议新建文件夹")
    default: action = activity.name
    }
    return activity.argsSummary.isEmpty ? action : "\(action)：\(activity.argsSummary)"
  }

  private var failedWriteActivity: AIChatStore.ToolActivity? {
    message.toolActivities.last { activity in
      activity.hasFailed && [
        "workspace_write_file", "workspace_edit_file", "workspace_create_folder",
      ].contains(activity.name)
    }
  }

  private var writingNoProposalMessage: String {
    guard let result = failedWriteActivity?.resultSummary else {
      return String(localized: "写作模式：本轮没有产生任何提案（模型只是文字描述）")
    }
    if result.contains("failed to match") || result.contains("did not match") {
      return String(localized: "写作模式：修改内容与当前文档不匹配，未生成提案")
    }
    if result.contains("missing 'path'") {
      return String(localized: "写作模式：模型没有提供文件路径，未生成提案")
    }
    if result.contains("cannot read") {
      return String(localized: "写作模式：无法读取目标文件，未生成提案")
    }
    if result.contains("already exists") {
      return String(localized: "写作模式：目标已存在，未生成新建提案")
    }
    return String(localized: "写作模式：写入工具校验失败，未生成提案")
  }

  /// 复制回复（唯一保留动作）：圆形底衬按钮，点击后图标短暂变对勾反馈
  private var copyButton: some View {
    Button {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(message.content, forType: .string)
      copyFeedback = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copyFeedback = false }
    } label: {
      Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc.fill")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(copyFeedback ? Color.green : Color.secondary)
        .frame(width: 22, height: 20)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(String(localized: "复制回复"))
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
      changeStore: AIChangeStore()
    )
    AIChatMessageRow(
      message: AIChatStore.ChatMessage(role: .assistant, content: "核心论点是 **注意力机制** 可以替代循环结构。"),
      isBusy: false,
      changeStore: AIChangeStore()
    )
  }
  .padding()
  .frame(width: 320)
}
