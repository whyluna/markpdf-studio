import AppKit
import SwiftUI

/// 中键点击识别（FR-1.4 标签中键关闭）：SwiftUI 无原生中键事件，下沉 AppKit。
struct MiddleClickView: NSViewRepresentable {
  var onMiddleClick: () -> Void

  func makeNSView(context: Context) -> MiddleClickNSView {
    let view = MiddleClickNSView()
    view.onMiddleClick = onMiddleClick
    return view
  }

  func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
    nsView.onMiddleClick = onMiddleClick
  }
}

final class MiddleClickNSView: NSView {
  var onMiddleClick: (() -> Void)?

  override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2 {
      onMiddleClick?()
    } else {
      super.otherMouseDown(with: event)
    }
  }
}
