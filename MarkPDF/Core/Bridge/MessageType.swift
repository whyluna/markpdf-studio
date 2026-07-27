import Foundation

/// 桥接消息类型（开发规范 §3.4：集中登记，禁止散点字符串）。
/// 新增消息类型须同步登记 Web 侧（Resources/Web/src）收发处。
enum BridgeMessageType: String {
  // native → web
  case setContent = "editor.setContent"
  case getContent = "editor.getContent"
  case setMode = "editor.setMode"
  case setTheme = "editor.setTheme"
  case insertAtCursor = "editor.insertAtCursor"
  case scrollToLine = "editor.scrollToLine"
  /// 编辑器排版（FR-7.2：字体/字号/行高）
  case setTypography = "editor.setTypography"
  /// 打字机模式开关（FR-2.10）
  case setTypewriter = "editor.setTypewriter"
  /// 专注模式开关（FR-2.10）
  case setFocusMode = "editor.setFocusMode"
  /// 取当前选区（FR-AI.2；带 id 请求-响应，应答 {text, from, to}，无选区 text=""）
  case getSelection = "editor.getSelection"
  /// 替换选区（FR-AI.2；带 id 请求-响应，应答 {replaced}；空选区拒绝不落改动）
  case replaceSelection = "editor.replaceSelection"

  // web → native
  case ready = "editor.ready"
  case contentChanged = "editor.contentChanged"
  case outline = "editor.outline"
  case openLink = "editor.openLink"
  case cursor = "editor.cursor"
  /// 粘贴/拖拽图片存盘请求（FR-2.5；带 id 请求-响应，应答 {path} 或 {error}）
  case saveImage = "editor.saveImage"
  /// 导出 HTML 请求（FR-2.9；带 id 请求-响应，应答 {title, html}）
  case exportHTML = "editor.exportHTML"
}
