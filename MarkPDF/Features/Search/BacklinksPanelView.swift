import SwiftUI

/// 反向链接面板（FR-5.4）：展示当前 md / pdf 被哪些文件引用，点击打开来源文件。
/// 用于 md 上下文右侧面板（大纲之下）与 PDF 侧栏「引用」段。
struct BacklinksPanelView: View {
  let target: URL?
  @EnvironmentObject private var backlinksStore: BacklinksStore
  @EnvironmentObject private var tabStore: TabStore

  var body: some View {
    VStack(spacing: 0) {
      Text("反向链接")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      Divider()
      content
    }
    .onAppear { backlinksStore.track(target) }
    .onChange(of: target) { newTarget in
      backlinksStore.track(newTarget)
    }
  }

  @ViewBuilder
  private var content: some View {
    if target == nil {
      placeholder(String(localized: "打开文件后\n显示引用它的文件"))
    } else if backlinksStore.items.isEmpty {
      placeholder(backlinksStore.isScanning ? String(localized: "扫描中…") : String(localized: "没有文件引用它"))
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          // 同一 md 可有多条链接指向目标（source 重复），\.source 作 id 会触发
          // SwiftUI 重复 ID 警告/渲染错乱——改用位置序号（结果按路径排序，帧内稳定）
          ForEach(Array(backlinksStore.items.enumerated()), id: \.offset) { _, item in
            row(item)
          }
        }
        .padding(8)
      }
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func row(_ item: Backlink) -> some View {
    Button {
      tabStore.open(url: item.source)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Label(item.source.lastPathComponent, systemImage: "doc.text")
          .font(.system(size: 13))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(item.text)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  BacklinksPanelView(target: URL(fileURLWithPath: "/tmp/a.pdf"))
    .environmentObject(BacklinksStore())
    .environmentObject(TabStore())
    .frame(width: 266, height: 240)
}
