import PDFKit
import SwiftUI

/// 批注草稿（FR-4.3）：打字只进草稿，编辑框关闭时一次性写入标注。
/// 每键直改 PDFAnnotation 会连带 PDFKit 失效重绘 + 防抖写回，是卡顿根因
final class CommentDraft: ObservableObject {
  @Published var text: String

  init(_ text: String) {
    self.text = text
  }
}

/// 批注编辑框（FR-4.3）：点击页边批注图标弹出，查看/编辑批注内容。
/// 文本区用 AppKit 原生 NSTextView（SwiftUI TextEditor 在 popover + 中文输入法下卡顿）。
/// 键位：↵ 提交并关闭（同点击空白处），⌘↵ 换行
struct CommentEditorView: View {
  @ObservedObject var draft: CommentDraft
  let onDelete: () -> Void
  /// ↵ 提交：关闭编辑框（内容由关闭流程一次性写回标注）
  let onCommit: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      PlainTextView(text: $draft.text, onCommit: onCommit)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 240, height: 150)
      HStack(spacing: 8) {
        Button(role: .destructive, action: onDelete) {
          Image(systemName: "trash")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("删除批注")
        Spacer()
        Text("⌘↵ 换行")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
        Text("\(draft.text.count) 字")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(10)
  }
}

/// 批注输入区（FR-4.3 键位）：↵ 提交并关闭、⌘↵ 换行。
/// 覆写 keyDown 而非走 doCommandBy：⌘↵ 不映射为标准编辑命令，拿不到回调
private final class CommentTextView: NSTextView {
  var onCommit: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    // 36 = Return，76 = 小键盘 Enter
    if event.keyCode == 36 || event.keyCode == 76 {
      if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
        insertNewline(nil)
      } else {
        onCommit?()
      }
      return
    }
    super.keyDown(with: event)
  }
}

/// NSTextView 包装的纯文本编辑区（流畅的 IME/打字体验）
private struct PlainTextView: NSViewRepresentable {
  @Binding var text: String
  let onCommit: () -> Void

  func makeNSView(context: Context) -> NSScrollView {
    // 手工搭 scrollView + 自定义 NSTextView：scrollableTextView() 造的是内建类，换不掉键位处理
    let scrollView = NSScrollView()
    // 透明底：透出下层的淡色圆角背景，白底在 popover 里太突兀
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    // 滚动条按需显示：内容未溢出时隐藏，超出文本框才出现
    scrollView.autohidesScrollers = true
    let textView = CommentTextView(frame: .zero)
    textView.onCommit = onCommit
    textView.isRichText = false
    textView.font = .systemFont(ofSize: 14.5)
    textView.textColor = .labelColor
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 4, height: 6)
    // 随宽度换行、纵向随内容增长（scrollableTextView 的默认配置，手工搭需自行设置）
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.delegate = context.coordinator
    textView.string = text
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? CommentTextView else { return }
    textView.onCommit = onCommit
    if textView.string != text {
      textView.string = text
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PlainTextView

    init(_ parent: PlainTextView) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }
  }
}

#Preview {
  CommentEditorView(draft: CommentDraft("示例批注"), onDelete: {}, onCommit: {})
    .padding()
}
