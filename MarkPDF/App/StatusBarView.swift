import SwiftUI

/// 窗口状态栏（FR-3.2；对齐设计稿 .statusbar，高 29px）。
/// pdf 上下文：文件名 · 页码 + 缩放控件；md 上下文：编辑模式；右侧常驻 UTF-8。
struct StatusBarView: View {
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @EnvironmentObject private var imageStore: ImagePreviewStore

  private var activeKind: FileNode.Kind? {
    tabStore.activeGroup.activeTab?.kind
  }

  var body: some View {
    HStack(spacing: 14) {
      if let tab = tabStore.activeGroup.activeTab, activeKind == .pdf {
        Text("\(tab.title) · 第 \(pdfStore.currentPage) / \(pdfStore.pageCount) 页")
      } else if let tab = tabStore.activeGroup.activeTab, activeKind == .image {
        Text(tab.title)
      }
      Spacer()
      switch activeKind {
      case .pdf:
        Text("PDF · 阅读")
        zoomControls(scale: pdfStore.scale, onZoomIn: pdfStore.zoomIn, onZoomOut: pdfStore.zoomOut)
      case .image:
        Text("图片 · 查看")
        zoomControls(scale: imageStore.scale, onZoomIn: imageStore.zoomIn, onZoomOut: imageStore.zoomOut)
      default:
        if let store = tabStore.activeEditorStore {
          MarkdownStatusView(store: store)
        } else {
          Text("Markdown · 所见即所得")
        }
      }
      Text("UTF-8")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .frame(height: 29)
    .background(.bar)
    .overlay(alignment: .top) {
      Divider()
    }
  }

  /// 缩放控件（设计稿 #sb-zoom：− / 百分比 / +）
  private func zoomControls(scale: CGFloat, onZoomIn: @escaping () -> Void, onZoomOut: @escaping () -> Void) -> some View {
    HStack(spacing: 6) {
      Button(action: onZoomOut) {
        Text("−")
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      Text("\(Int((scale * 100).rounded()))%")
        .frame(minWidth: 44)
      Button(action: onZoomIn) {
        Text("+")
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
  }
}

/// Markdown 状态区（FR-2.8 字数 / 字符 / 预计阅读时长 + 编辑模式）：
/// 显式 @ObservedObject 注入 EditorStore——嵌套 ObservableObject 的变化不向上冒泡，
/// 由真正读它的子视图持有观测，击键后字数 / 切模式后文案即时刷新
private struct MarkdownStatusView: View {
  @ObservedObject var store: EditorStore

  var body: some View {
    // FR-2.8：字数 / 字符 / 预计阅读时长
    Text("\(store.stats.words.formatted()) 字 · \(store.stats.characters.formatted()) 字符 · 约 \(store.stats.readingMinutes) 分钟")
    Text("Markdown · \(store.mode.title)")
  }
}

#Preview {
  StatusBarView()
    .environmentObject(TabStore())
    .environmentObject(PDFReaderStore())
    .environmentObject(ImagePreviewStore())
}
