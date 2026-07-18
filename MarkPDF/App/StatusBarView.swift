import SwiftUI

/// 窗口状态栏（FR-3.2；对齐设计稿 .statusbar，高 29px）。
/// pdf 上下文：文件名 · 页码 + 缩放控件；md 上下文：编辑模式；右侧常驻 UTF-8。
struct StatusBarView: View {
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var pdfStore: PDFReaderStore

  private var isPDF: Bool {
    tabStore.activeGroup.activeTab?.kind == .pdf
  }

  var body: some View {
    HStack(spacing: 14) {
      if isPDF, let tab = tabStore.activeGroup.activeTab {
        Text("\(tab.title) · 第 \(pdfStore.currentPage) / \(pdfStore.pageCount) 页")
      }
      Spacer()
      if isPDF {
        Text("PDF · 阅读")
        zoomControls
      } else {
        Text("Markdown · \(tabStore.activeEditorStore?.mode.title ?? "所见即所得")")
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
  private var zoomControls: some View {
    HStack(spacing: 6) {
      Button(action: pdfStore.zoomOut) {
        Text("−")
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      Text("\(Int((pdfStore.scale * 100).rounded()))%")
        .frame(minWidth: 44)
      Button(action: pdfStore.zoomIn) {
        Text("+")
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  StatusBarView()
    .environmentObject(TabStore())
    .environmentObject(PDFReaderStore())
}
