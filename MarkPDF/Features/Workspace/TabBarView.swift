import AppKit
import os
import SwiftUI

/// 标签栏（FR-1.4；对齐设计稿 .tabbar）：顶部圆角标签、hover 关闭钮、+ 新建、
/// 点击切换、中键关闭、拖拽重排（VSCode 式竖线指示落点）、跨组拖移、拖到窗口
/// 右缘分栏。
///
/// 重排走 DragGesture 直算落点，不用系统拖放：onDrag 会话恒为 .copy 会带「+」徽标，
/// 自定义 NSDraggingSource 与 SwiftUI 布局更新互相拉扯导致拖拽中画面闪烁。
/// 落点指示为 VSCode 式悬浮竖线（overlay 定位，不占布局）——拖拽期间标签布局
/// 全程不变；此前让位间隙是布局子节点，逐帧增删改把横向 ScrollView 的内容高度
/// 反复撑大（「标签栏变下拉框」+ 闪烁的根因），松手才执行重排并动画归位。
struct TabBarView: View {
  @ObservedObject var group: TabGroup
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var tabDragStore: TabDragStore

  /// 拖拽中的标签 id（nil = 未拖拽）；驱动被拖标签半透明
  @State private var dragTabID: EditorTab.ID?
  /// 本栏手势落点插入位置（0..count；nil = 无落点）
  @State private var dropTargetIndex: Int?
  /// 各标签的全局帧（GeometryReader 上报；与手势的全局指针直接可比，
  /// 天然感知滚动偏移——此前用栏内局部坐标 + HStack 内容帧判定，空栏只剩
  /// 26pt 的「+」按钮宽、溢出栏超出自身视口，跨栏判定全盘失效）
  @State private var tabFrames: [EditorTab.ID: CGRect] = [:]
  /// 本栏视口（ScrollView，即分栏里本栏的实际条带）的全局帧——
  /// 范围判定/竖线定位一律以它为准，不用内容帧
  @State private var myGlobalFrame: CGRect = .zero
  /// 标签栏高度（竖线高度用）
  @State private var tabBarHeight: CGFloat = 0
  /// 标签栏内容（HStack）的全局帧：内容宽度 + 滚动偏移（细滚动条定位用；
  /// 滚动时其 minX 相对视口左移，天然给出已滚出量）
  @State private var contentFrame: CGRect = .zero

  var body: some View {
    // FR-1.4：标签过多时横向滚动（挤压不可读的修复）；激活标签自动滚动可见。
    // 系统指示条太粗（无法调粗细）——关掉，用底部自绘 3pt 胶囊细条（见 scrollIndicator）
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .bottom, spacing: 3) {
          ForEach(group.tabs) { tab in
            TabItemView(
              tab: tab,
              isActive: tab.id == group.activeTabID,
              editorStore: group.editorStores[tab.id],
              onSelect: {
                group.activate(tab)
                tabStore.activeGroupID = group.id
              },
              onClose: {
                group.close(tab)
              }
            )
            .id(tab.id)
            // 被拖标签原位淡化（不消失，用户反馈留白槽太突兀）；
            // 跟随鼠标的幽灵浮层见 ContentView.TabDragGhostOverlay
            .opacity(dragTabID == tab.id ? 0.35 : 1)
            .background(
              // 上报标签全局帧：与手势全局指针直接对照求插入位置
              GeometryReader { geo in
                Color.clear.preference(
                  key: TabFrameKey.self,
                  value: [tab.id: geo.frame(in: .global)]
                )
              }
            )
            .gesture(
              DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                  handleDragChanged(tab: tab, globalLocation: value.location)
                }
                .onEnded { _ in
                  handleDragEnded(tab: tab)
                }
            )
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
        }
        // 收集各标签帧（落点/竖线定位的数据源；漏接 onPreferenceChange 会让
        // tabFrames 恒为空——竖线永远落在兜底位置、跨栏落点失效的根因）
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
        // 内容全局帧：内容宽度 + 滚动偏移（细滚动条定位用）
        .background(
          GeometryReader { geo in
            Color.clear
              .onAppear { contentFrame = geo.frame(in: .global) }
              .onChange(of: geo.frame(in: .global)) { contentFrame = $0 }
          }
        )
        // 首标签顶到内容区左缘：其左缘竖线与 PDF 显示区左缘重合
        //（此前内缩 8pt 形成第二条错位竖线）；尾侧保留 8pt 收尾
        .padding(.leading, 0)
        .padding(.trailing, 8)
        .padding(.top, 6)
        // 底部 3pt 为细滚动条专用条带（此前细条直接压在标签底边上）
        .padding(.bottom, 3)
      }
      // 与窗口工具栏同一 bar 材质，避免两种灰色与阴影叠出不协调感
      .background(.bar)
      .overlay(alignment: .bottom) {
        Divider()
      }
      // 细滚动条：内容溢出时在栏底 3pt 专用条带内显示胶囊拇指
      .overlay(alignment: .bottomLeading) {
        scrollIndicator
          .padding(.leading, 2)
      }
      // 视口全局帧 + 高度：范围判定与竖线定位的基准（挂在 ScrollView 上，
      // 测的是分栏里本栏的实际条带，而不是可滚动的内容宽度）
      .background(
        GeometryReader { geo in
          Color.clear
            .onAppear {
              tabBarHeight = geo.size.height
              myGlobalFrame = geo.frame(in: .global)
            }
            .onChange(of: geo.size.height) { newHeight in
              tabBarHeight = newHeight
            }
            .onChange(of: geo.frame(in: .global)) { newFrame in
              myGlobalFrame = newFrame
            }
        }
      )
      // 落点竖线（VSCode 式）：悬浮 overlay 定位在标签间隙，不占布局空间，
      // 拖拽期间标签栏高度/布局零变化
      .overlay(alignment: .topLeading) {
        if let lineX = insertionLineX {
          RoundedRectangle(cornerRadius: 1.25)
            .fill(Color.accentColor)
            .frame(width: 2.5, height: max(tabBarHeight - 9, 16))
            .position(x: lineX, y: tabBarHeight / 2)
            .allowsHitTesting(false)
        }
      }
      .onAppear {
        // 恢复现场后激活标签可能在可视区外
        if let activeID = group.activeTabID {
          proxy.scrollTo(activeID, anchor: .center)
        }
      }
      .onChange(of: group.activeTabID) { newActiveID in
        // 等新标签完成布局再滚动（激活变更先于视图布局）
        guard let newActiveID else { return }
        DispatchQueue.main.async {
          withAnimation { proxy.scrollTo(newActiveID, anchor: .center) }
        }
      }
      // 跨栏悬停：共享指针每帧变化时自判是否为落点栏
      .onChange(of: tabDragStore.dragPointer) { pointer in
        updateCrossTarget(pointer: pointer)
      }
    }
  }

  /// 本栏当前落点索引：跨栏悬停时用共享落点，否则用本栏手势落点
  private var gapIndex: Int? {
    if let cross = tabDragStore.crossTarget, cross.groupID == group.id {
      return cross.index
    }
    return dropTargetIndex
  }

  /// 落点竖线的 x（视口局部坐标）：目标索引前侧标签的全局边界减视口原点；
  /// 空栏（无标签帧）落在视口最左。nil = 无拖拽落点
  private var insertionLineX: CGFloat? {
    guard let target = gapIndex, myGlobalFrame != .zero else { return nil }
    let globalX: CGFloat
    if target < group.tabs.count, let frame = tabFrames[group.tabs[target].id] {
      globalX = frame.minX - 1.5
    } else if let last = group.tabs.last, let frame = tabFrames[last.id] {
      globalX = frame.maxX + 1.5
    } else {
      globalX = myGlobalFrame.minX + 1.25
    }
    // 夹回视口内（目标标签可能在滚动区外）
    let local = globalX - myGlobalFrame.minX
    return min(max(local, 1.25), max(myGlobalFrame.width - 1.25, 1.25))
  }

  /// 细滚动条拇指：拇指宽 = 视口²/内容宽，位置 = 已滚出比例 × 剩余行程；
  /// 内容不溢出时不显示
  @ViewBuilder
  private var scrollIndicator: some View {
    let viewport = myGlobalFrame.width
    let content = contentFrame.width
    if myGlobalFrame != .zero, content > viewport + 1 {
      let offset = max(0, myGlobalFrame.minX - contentFrame.minX)
      let travel = content - viewport
      let thumbWidth = max(viewport * viewport / content, 24)
      let thumbX = travel > 0 ? (offset / travel) * (viewport - thumbWidth - 4) : 0
      Capsule()
        .fill(Color.primary.opacity(0.3))
        .frame(width: thumbWidth, height: 3)
        .offset(x: thumbX)
        .allowsHitTesting(false)
    }
  }

  /// 拖拽进行中：首次回调确定被拖标签（顺带记录其宽度供幽灵浮层等宽复刻）；
  /// 随后发布共享指针并求本栏落点（指针 x 必须落在本栏视口内）
  private func handleDragChanged(tab: EditorTab, globalLocation: CGPoint) {
    if dragTabID == nil {
      dragTabID = tab.id
      tabDragStore.draggingTab = (tab, group.id)
      tabDragStore.ghostWidth = tabFrames[tab.id]?.width
    }
    guard dragTabID == tab.id else { return }
    tabDragStore.dragPointer = globalLocation
    if myGlobalFrame != .zero,
      globalLocation.x >= myGlobalFrame.minX, globalLocation.x <= myGlobalFrame.maxX
    {
      dropTargetIndex = localTargetIndex(forGlobalX: globalLocation.x)
    } else {
      dropTargetIndex = nil
    }
  }

  /// 落点 = 第一个 midX 在指针右侧的标签之前（默认末尾）。
  /// 指在被拖标签自身左右半区分别解算到自身前/后——落定均为原位不动，
  /// 竖线正确表达「留在当前位置」，无需特判排除
  private func localTargetIndex(forGlobalX x: CGFloat) -> Int {
    var target = group.tabs.count
    for (index, t) in group.tabs.enumerated() {
      guard let frame = tabFrames[t.id] else { continue }
      if x < frame.midX {
        target = index
        break
      }
    }
    return target
  }

  /// 跨栏悬停自判：指针位于本栏视口（含栏下方的宽松竖直带——拖拽时指针常压在
  /// 栏条略下方）且拖拽来自其他栏时，维护共享落点（含插入索引）
  private func updateCrossTarget(pointer: CGPoint?) {
    guard let pointer,
      let dragging = tabDragStore.draggingTab,
      dragging.from != group.id,
      myGlobalFrame != .zero,
      myGlobalFrame.insetBy(dx: 0, dy: -100).contains(pointer)
    else {
      // 指针不在本栏：清掉自己维护的落点（若有）
      if tabDragStore.crossTarget?.groupID == group.id {
        tabDragStore.crossTarget = nil
      }
      return
    }
    var target = group.tabs.count
    for (index, t) in group.tabs.enumerated() {
      guard let frame = tabFrames[t.id] else { continue }
      if pointer.x < frame.midX {
        target = index
        break
      }
    }
    // 未变化不重复发布（指针每帧都进来，跨过标签中线才改索引）
    if let cross = tabDragStore.crossTarget, cross.groupID == group.id, cross.index == target {
      return
    }
    tabDragStore.crossTarget = (groupID: group.id, index: target)
    Logger.workspace.info(
      "[TAB-DRAG] 跨栏落点 栏=\(group.id.uuidString, privacy: .public) 索引=\(target) 指针=(\(pointer.x), \(pointer.y)) 视口帧=\(String(describing: myGlobalFrame), privacy: .public)"
    )
  }

  /// 拖拽结束：按落点执行 边缘分栏 / 跨栏移入 / 组内重排，松手动画归位
  private func handleDragEnded(tab: EditorTab) {
    let localTarget = dropTargetIndex.flatMap { $0 < group.tabs.count ? group.tabs[$0] : nil }
    defer {
      dragTabID = nil
      dropTargetIndex = nil
      tabDragStore.draggingTab = nil
      tabDragStore.dragPointer = nil
      tabDragStore.crossTarget = nil
    }
    guard dragTabID == tab.id, let dragging = tabDragStore.draggingTab else { return }
    let pointer = tabDragStore.dragPointer
    let edge = tabDragStore.edgeDropFrame
    let cross = tabDragStore.crossTarget
    Logger.workspace.info(
      "[TAB-DRAG] 松手 指针=\(pointer.map { "(\($0.x), \($0.y))" } ?? "nil", privacy: .public) 边缘帧=\(edge.map(String.init(describing:)) ?? "nil", privacy: .public) 跨栏=\(cross.map { "\($0.groupID.uuidString)#\($0.index)" } ?? "nil", privacy: .public) 本栏落点=\(dropTargetIndex.map(String.init) ?? "nil", privacy: .public)"
    )
    withAnimation(.easeOut(duration: 0.15)) {
      // 窗口右缘落点：分栏模式移入最右组，单栏模式新建右组
      if let pointer,
        let edge = tabDragStore.edgeDropFrame,
        edge.contains(pointer),
        let source = tabStore.groups.first(where: { $0.id == dragging.from })
      {
        Logger.workspace.info("[TAB-DRAG] 落点分支=边缘分栏")
        let target = tabStore.isSplit ? tabStore.groups.last : nil
        tabStore.moveTab(dragging.tab, from: source, to: target)
        return
      }
      // 跨栏落点：指针停在另一栏标签栏内
      if let cross = tabDragStore.crossTarget, cross.groupID != group.id,
        let source = tabStore.groups.first(where: { $0.id == dragging.from }),
        let destination = tabStore.groups.first(where: { $0.id == cross.groupID })
      {
        Logger.workspace.info("[TAB-DRAG] 落点分支=跨栏移入")
        let before = cross.index < destination.tabs.count ? destination.tabs[cross.index] : nil
        tabStore.moveTab(dragging.tab, from: source, to: destination, before: before)
        return
      }
      // 本栏内重排（原位不动时 moveTab 自守卫为无操作）
      Logger.workspace.info("[TAB-DRAG] 落点分支=本栏重排")
      group.moveTab(tab, before: localTarget)
    }
  }
}

/// 标签帧上报键（全局坐标系：与手势全局指针直接可比，天然感知滚动偏移）
private struct TabFrameKey: PreferenceKey {
  static var defaultValue: [EditorTab.ID: CGRect] = [:]
  static func reduce(value: inout [EditorTab.ID: CGRect], nextValue: () -> [EditorTab.ID: CGRect]) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// 单个标签（设计稿 .tab：激活白底带边框、hover 显示关闭钮）
private struct TabItemView: View {
  let tab: EditorTab
  let isActive: Bool
  /// 该标签的编辑状态（pdf/图片标签为 nil）；橙点由 TabBadgeView 显式观测
  let editorStore: EditorStore?
  let onSelect: () -> Void
  let onClose: () -> Void
  @State private var isHovered = false
  /// 关闭钮自身悬停：小手光标 + 图标提亮/底衬，让「x」的命中范围可见
  @State private var isCloseHovered = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: tab.iconName)
        .font(.system(size: 11))
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
      // 抱紧内容、超上限截断：单用 frame(maxWidth:) 在宽裕提议下会贪满上限
      //（标题居中、两侧大片空白——“尾部空白大”的根因）；补 fixedSize 让帧取
      // ideal = min(全文宽, 上限)，短标题零空白、长标题定点截断
      Text(tab.title)
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 190, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
      if let editorStore {
        TabBadgeView(store: editorStore)
      }
      // 关闭钮常驻占位（不悬停时仅透明）：hover 只显隐图标、不改变标签宽度，
      // 否则悬停时宽度突变会打断用户对“x”的位置预期
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(isCloseHovered ? Color.primary : Color.secondary)
          .frame(width: 18, height: 18)
          .background(
            // 悬停底衬：点亮命中范围
            RoundedRectangle(cornerRadius: 5)
              .fill(Color.primary.opacity(isCloseHovered ? 0.12 : 0))
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(isHovered || isActive ? 1 : 0)
      .allowsHitTesting(isHovered || isActive)
      .onHover { hovering in
        isCloseHovered = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    }
    .padding(.horizontal, 5)
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
      Button(tab.title == "新标签页" ? "新建标签页" : "关闭标签页") { onClose() }
    }
  }
}

/// 未落盘改动橙点（FR-2.7）：显式 @ObservedObject 注入 EditorStore——
/// 嵌套 ObservableObject 的变化不向上冒泡，须由真正读它的子视图持有观测，
/// 击键点亮 / 自动保存后熄灭才能即时刷新
private struct TabBadgeView: View {
  @ObservedObject var store: EditorStore

  var body: some View {
    if store.hasUnsavedChanges {
      Circle()
        .fill(Color.orange)
        .frame(width: 6, height: 6)
        .help("有未落盘的改动")
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
