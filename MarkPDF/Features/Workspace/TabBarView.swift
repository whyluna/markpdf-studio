import SwiftUI
import UniformTypeIdentifiers

/// 标签栏（FR-1.4；对齐设计稿 .tabbar）：顶部圆角标签、hover 关闭钮、+ 新建、
/// 点击切换、中键关闭、拖拽重排、跨组拖移。
struct TabBarView: View {
  @ObservedObject var group: TabGroup
  @EnvironmentObject private var tabStore: TabStore

  var body: some View {
    HStack(alignment: .bottom, spacing: 3) {
      ForEach(group.tabs) { tab in
        TabItemView(
          tab: tab,
          isActive: tab.id == group.activeTabID,
          hasUnsavedChanges: group.editorStores[tab.id]?.hasUnsavedChanges ?? false,
          onSelect: {
            group.activate(tab)
            tabStore.activeGroupID = group.id
          },
          onClose: {
            group.close(tab)
          }
        )
        .onDrag {
          tabStore.draggingTab = (tab, group.id)
          return NSItemProvider(object: tab.id as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
          // 拖到某标签上 = 移到该标签之前（同组重排 / 跨组移入）
          guard let dragging = tabStore.draggingTab else { return false }
          moveDragged(dragging, before: tab)
          return true
        }
      }
      Button {
        group.openDraft()
        tabStore.activeGroupID = group.id
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.bottom, 3)
      .help("新标签页")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.top, 6)
    .background(Color(nsColor: .underPageBackgroundColor))
    .overlay(alignment: .bottom) {
      Divider()
    }
    .onDrop(of: [.text], isTargeted: nil) { _ in
      // 拖到栏空白处 = 移到该组末尾
      guard let dragging = tabStore.draggingTab else { return false }
      moveDragged(dragging, before: nil)
      return true
    }
  }

  private func moveDragged(_ dragging: (tab: EditorTab, from: TabGroup.ID), before target: EditorTab?) {
    defer { tabStore.draggingTab = nil }
    if dragging.from == group.id {
      group.moveTab(dragging.tab, before: target)
    } else if let source = tabStore.groups.first(where: { $0.id == dragging.from }) {
      tabStore.moveTab(dragging.tab, from: source, to: group)
    }
  }
}

/// 单个标签（设计稿 .tab：激活白底带边框、hover 显示关闭钮）
private struct TabItemView: View {
  let tab: EditorTab
  let isActive: Bool
  let hasUnsavedChanges: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: tab.iconName)
        .font(.system(size: 11))
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
      Text(tab.title)
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 160)
      if hasUnsavedChanges {
        Circle()
          .fill(Color.orange)
          .frame(width: 6, height: 6)
          .help("有未落盘的改动")
      }
      if isHovered || isActive {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(
      TopRoundedRectangle(radius: 8)
        .fill(isActive ? Color(nsColor: .windowBackgroundColor) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
    )
    .overlay {
      if isActive {
        TopRoundedRectangle(radius: 8)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .onHover { isHovered = $0 }
    .background {
      // 中键关闭（FR-1.4）
      MiddleClickView(onMiddleClick: onClose)
    }
    .contextMenu {
      Button("关闭标签", action: onClose)
    }
  }
}

/// 顶部圆角矩形（标签形状；部署目标无 RoundedRectangle corners 参数，自绘）
struct TopRoundedRectangle: Shape {
  var radius: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addArc(
      center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
      radius: radius,
      startAngle: .degrees(180),
      endAngle: .degrees(270),
      clockwise: false
    )
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    path.addArc(
      center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
      radius: radius,
      startAngle: .degrees(270),
      endAngle: .degrees(360),
      clockwise: false
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

#Preview {
  TabBarView(group: TabGroup())
    .environmentObject(TabStore())
}
