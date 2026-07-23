import AppKit
import os
import SwiftUI
import Translation

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
          Text(translated)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        case .failure(let message):
          VStack(alignment: .leading, spacing: 6) {
            Text(message)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
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
