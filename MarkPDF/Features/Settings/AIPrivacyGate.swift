import AppKit

/// 首次使用任一 AI 功能前的隐私告知（FR-AI.4 / 开发规范 §10）：
/// 明确告知内容将发往用户自行配置的第三方服务；「继续」记忆选择，之后不再弹。
@MainActor
enum AIPrivacyGate {
  @discardableResult
  static func ensureAcknowledged(store: AISettingsStore) -> Bool {
    if store.privacyNoticeAcknowledged { return true }
    let alert = NSAlert()
    alert.messageText = "使用 AI 功能前请知悉"
    alert.informativeText = """
      AI 功能会将你选中的文本或文档内容，发送到你自行配置的第三方 AI 服务\
      （OpenAI、DeepSeek、Claude 等）。

      MarkPDF 自身不经过任何服务器、不收集遥测；API Key 仅保存在系统钥匙串。
      """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "我已知晓，继续使用")
    alert.addButton(withTitle: "取消")
    let acknowledged = alert.runModal() == .alertFirstButtonReturn
    if acknowledged {
      store.privacyNoticeAcknowledged = true
    }
    return acknowledged
  }
}
