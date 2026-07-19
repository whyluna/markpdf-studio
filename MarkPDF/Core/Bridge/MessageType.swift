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

  // web → native
  case ready = "editor.ready"
  case contentChanged = "editor.contentChanged"
  case outline = "editor.outline"
  case openLink = "editor.openLink"
  case cursor = "editor.cursor"
}
