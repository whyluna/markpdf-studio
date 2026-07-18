import AppKit
import SwiftUI

/// 支持命令拦截的搜索框（FR-6.1）：↑/↓ 导航、Enter 提交、Esc 取消。
/// SwiftUI 的 onMoveCommand/onKeyPress 需 macOS 14；macOS 13 走 NSTextField 的
/// `control(_:textView:doCommandBy:)` 经典通道。
struct CommandSearchField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var onMoveUp: () -> Void
  var onMoveDown: () -> Void
  var onSubmit: () -> Void
  var onCancel: () -> Void

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.placeholderString = placeholder
    field.delegate = context.coordinator
    field.font = .systemFont(ofSize: 18)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    // 挂载后抢焦点（此时 window 可能尚未就绪，延后一拍）
    DispatchQueue.main.async {
      field.window?.makeFirstResponder(field)
    }
    return field
  }

  func updateNSView(_ nsView: NSTextField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    nsView.placeholderString = placeholder
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    private var parent: CommandSearchField

    init(_ parent: CommandSearchField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.moveUp(_:)):
        parent.onMoveUp()
        return true
      case #selector(NSResponder.moveDown(_:)):
        parent.onMoveDown()
        return true
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onCancel()
        return true
      default:
        return false
      }
    }
  }
}
