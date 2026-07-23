import AppKit
import os
import SwiftUI
import Translation

/// 可选择/可滚动的只读文本区（翻译气泡用）：
/// AppKit NSTextView——I 形光标与文本选择原生正确；
/// overlay 滚动条自动显隐、不占轨道（内容未溢出不出现，滚动时才浮现）
struct SelectableTextView: NSViewRepresentable {
  let text: String
  /// 高度上限（sizeThatFits 里夹取）
  var maxHeight: CGFloat = 240

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = .systemFont(ofSize: 13)
    textView.textColor = .labelColor
    textView.textContainerInset = NSSize(width: 0, height: 2)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.string = text
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let textView = scrollView.documentView as! NSTextView
    if textView.string != text {
      textView.string = text
    }
  }

  /// 内容自适应高度（不超过 maxHeight），保证短译文不高、长译文滚动
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    guard let textView = nsView.documentView as? NSTextView,
      let layoutManager = textView.layoutManager,
      let container = textView.textContainer
    else { return nil }
    let width = proposal.width ?? 280
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: container)
    let height = layoutManager.usedRect(for: container).height + 8
    return CGSize(width: width, height: min(height, maxHeight))
  }
}
/// 划词翻译气泡（FR-AI.1）：贴在浮动工具条正下方，
/// 展示译文 / 加载 / 失败三态，带复制与关闭。
struct TranslationBubbleView: View {
  @ObservedObject var store: TranslationStore
  let onRetry: () -> Void

  var body: some View {
    if store.phase != .hidden {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(store.engineTitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Spacer()
          if case .success(let translated) = store.phase {
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(translated, forType: .string)
            } label: {
              Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制译文")
          }
          Button {
            store.reset()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.secondary)
              .frame(width: 22, height: 22)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("关闭")
        }
        switch store.phase {
        case .hidden:
          EmptyView()
        case .translating:
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text("翻译中…")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        case .success(let translated):
          if store.wasTruncated {
            Text("原文超长，AI 引擎仅翻译前 \(TranslationStore.maxAIInputCharacters) 字")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
          // 高度上限 240pt、超出滚动；AppKit 文本区：I 形光标/文本选择原生正确，
          // overlay 滚动条不占轨道（无 SwiftUI 滚动条的白底突兀）
          SelectableTextView(text: translated)
            .frame(maxWidth: .infinity, maxHeight: 240)
        case .failure(let message):
          VStack(alignment: .leading, spacing: 6) {
            ScrollView {
              Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Button("重试", action: onRetry)
              .controlSize(.small)
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(width: 300, alignment: .leading)
      .contentShape(Rectangle())
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.primary.opacity(0.1), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }
  }
}
