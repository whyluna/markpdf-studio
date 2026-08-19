import AppKit

/// 首次使用任一 AI 功能前的隐私告知（FR-AI.4 / 开发规范 §10）：
/// 明确告知内容将发往用户自行配置的第三方服务；「继续」记忆选择，之后不再弹。
@MainActor
enum AIPrivacyGate {
  /// 会话级拒绝记忆：用户点过「取消」后，自动触发（划词松手）不再重弹模态窗轰炸；
  /// 仅手动点击（用户明确意图）才再次提示
  private static var declinedThisSession = false

  @discardableResult
  static func ensureAcknowledged(store: AISettingsStore, allowPrompt: Bool = true) -> Bool {
    if store.privacyNoticeAcknowledged { return true }
    if declinedThisSession, !allowPrompt { return false }
    let alert = NSAlert()
    alert.messageText = String(localized: "使用 AI 功能前请知悉")
    alert.informativeText = String(localized: """
      AI 功能会将你选中的文本或文档内容，发送到你自行配置的第三方 AI 服务（OpenAI、DeepSeek、Claude 等）。

      MarkPDF 自身不经过任何服务器、不收集遥测；API Key 仅保存在本机（应用沙盒容器内）。
      """)
    alert.alertStyle = .informational
    alert.addButton(withTitle: String(localized: "我已知晓，继续使用"))
    alert.addButton(withTitle: String(localized: "取消"))
    let acknowledged = alert.runModal() == .alertFirstButtonReturn
    if acknowledged {
      store.privacyNoticeAcknowledged = true
      declinedThisSession = false
    } else {
      declinedThisSession = true
    }
    return acknowledged
  }
}
