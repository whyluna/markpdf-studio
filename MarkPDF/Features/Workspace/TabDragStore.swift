import Foundation

/// 标签拖拽协调（跨分栏落点，FR-1.4）：拖拽期间由源栏手势每帧写入指针位置，
/// 各栏据此自判是否为跨栏落点目标并维护 crossTarget；源栏松手时按落点执行
/// 组内重排 / 跨栏移入 / 边缘分栏。
/// 独立于 TabStore——拖拽状态若挂在 TabStore 上，TabGroupPane/ContentView
/// 整棵会随指针 60Hz 重算，正文渲染白白受累（TabBarView 与边缘落点条才观测本 store）
@MainActor
final class TabDragStore: ObservableObject {
  /// 拖拽中的标签（源栏手势启动时写入，结束时清空）
  @Published var draggingTab: (tab: EditorTab, from: TabGroup.ID)?
  /// 被拖标签的实测宽度（源栏手势启动时写入；幽灵浮层按此等宽复刻原标签）
  @Published var ghostWidth: CGFloat?
  /// 拖拽指针的全局坐标（源栏手势每帧写入；其他栏据此判定自己是否为落点）
  @Published var dragPointer: CGPoint?
  /// 当前跨栏落点（目标栏 + 插入索引；指针悬停其上的栏维护）
  @Published var crossTarget: (groupID: TabGroup.ID, index: Int)?
  /// 窗口右缘「拖到此处分栏」落点条的全局帧（ContentView 上报）
  @Published var edgeDropFrame: CGRect?
}
