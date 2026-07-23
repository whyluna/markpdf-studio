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
struct CommentEditorView: View {
  @ObservedObject var draft: CommentDraft
  let onDelete: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      PlainTextView(text: $draft.text)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 240, height: 150)
      HStack {
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
        Text("\(draft.text.count) 字")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(10)
  }
}

/// NSTextView 包装的纯文本编辑区（流畅的 IME/打字体验）
private struct PlainTextView: NSViewRepresentable {
  @Binding var text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    // 透明底：透出下层的淡色圆角背景，白底在 popover 里太突兀
    scrollView.drawsBackground = false
    // 滚动条按需显示：内容未溢出时隐藏，超出文本框才出现
    scrollView.autohidesScrollers = true
    let textView = scrollView.documentView as! NSTextView
    textView.isRichText = false
    textView.font = .systemFont(ofSize: 14.5)
    textView.textColor = .labelColor
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 4, height: 6)
    textView.delegate = context.coordinator
    textView.string = text
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let textView = scrollView.documentView as! NSTextView
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
  CommentEditorView(draft: CommentDraft("示例批注"), onDelete: {})
    .padding()
}
