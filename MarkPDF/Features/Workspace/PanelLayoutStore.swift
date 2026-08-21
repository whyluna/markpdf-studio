import Foundation

/// 边栏布局状态（左右栏宽度/显隐）：拖拽期间以 60Hz 逐帧直写，必须与
/// WorkspaceStore 隔离——若挂在 WorkspaceStore 上，ContentView（持有 .toolbar）
/// 会随每帧宽度重算整棵 body，工具栏跟着逐帧重建（拖右栏时顶部工具栏
/// 「一起移动」的根因）。只有真正读布局状态的子视图（面板宿主/工具栏按钮）观测本 store。
/// 持久化去抖：拖拽中不写盘，停 0.4s 后落一次
@MainActor
final class PanelLayoutStore: ObservableObject {
  /// 左侧文件树列宽范围（自定义侧栏，宽度由状态直接指定——
  /// 消融实验证实 NavigationSplitView 的列宽协商层存在不可修的宽度振荡）
  static let fileSidebarMinWidth: CGFloat = 238
  static let fileSidebarMaxWidth: CGFloat = 360
  static let fileSidebarDefaultWidth: CGFloat = 260
  /// 右侧面板列宽范围（复刻原系统检查器 inspectorColumnWidth 280/300/360）
  static let detailPanelMinWidth: CGFloat = 280
  static let detailPanelMaxWidth: CGFloat = 360
  static let detailPanelDefaultWidth: CGFloat = 300

  nonisolated static func clampedFileSidebarWidth(_ width: CGFloat) -> CGFloat {
    min(max(width, fileSidebarMinWidth), fileSidebarMaxWidth)
  }

  nonisolated static func clampedDetailPanelWidth(_ width: CGFloat) -> CGFloat {
    min(max(width, detailPanelMinWidth), detailPanelMaxWidth)
  }

  /// 左侧文件树列宽（拖拽条钳制后直写）
  @Published var fileSidebarWidth: CGFloat {
    didSet { schedulePersist() }
  }

  /// 右侧面板列宽（拖拽条钳制后直写）
  @Published var detailPanelWidth: CGFloat {
    didSet { schedulePersist() }
  }

  /// 左侧文件树显隐（工具栏导航位按钮切换）
  @Published var isFileSidebarPresented: Bool {
    didSet { schedulePersist() }
  }

  /// 右侧面板显隐（会话态，不持久）：只有工具栏按钮能切换——
  /// 自定义面板无系统检查器「拖过最窄即收起」的行为，拖拽只调宽度
  @Published var isDetailPanelPresented = true

  private let defaults = UserDefaults.standard
  private var persistTask: Task<Void, Never>?
  /// 拖动期间列宽继续逐帧发布，但 UserDefaults 去抖任务只在松手后创建一次。
  /// 否则每帧取消/重建 MainActor Task 也会挤占布局时间。
  private var activeResizeCount = 0
  private enum Key {
    static let fileSidebarWidth = "workspace.fileSidebarWidth"
    static let isFileSidebarPresented = "workspace.isFileSidebarPresented"
    static let detailPanelWidth = "workspace.detailPanelWidth"
  }

  init() {
    // 键沿用 WorkspaceStore 时期的键名，既有偏好无感迁移
    let storedWidth = defaults.double(forKey: Key.fileSidebarWidth)
    fileSidebarWidth = Self.clampedFileSidebarWidth(
      storedWidth > 0 ? storedWidth : Self.fileSidebarDefaultWidth
    )
    let storedDetailWidth = defaults.double(forKey: Key.detailPanelWidth)
    detailPanelWidth = Self.clampedDetailPanelWidth(
      storedDetailWidth > 0 ? storedDetailWidth : Self.detailPanelDefaultWidth
    )
    isFileSidebarPresented = defaults.object(forKey: Key.isFileSidebarPresented) as? Bool ?? true
  }

  func beginResize() {
    activeResizeCount += 1
    persistTask?.cancel()
    persistTask = nil
  }

  func endResize() {
    activeResizeCount = max(0, activeResizeCount - 1)
    if activeResizeCount == 0 {
      schedulePersist()
    }
  }

  /// 去抖落盘：拖拽每帧写宽度不再同步写 UserDefaults（此前 60Hz 磁盘 IO）
  private func schedulePersist() {
    guard activeResizeCount == 0 else { return }
    persistTask?.cancel()
    let fileSidebarWidth = Double(fileSidebarWidth)
    let detailPanelWidth = Double(detailPanelWidth)
    let isFileSidebarPresented = isFileSidebarPresented
    let fileSidebarWidthKey = Key.fileSidebarWidth
    let detailPanelWidthKey = Key.detailPanelWidth
    let isFileSidebarPresentedKey = Key.isFileSidebarPresented
    // UserDefaults 线程安全；延迟与写盘都放到 utility task，避免 mouseUp 后
    // 0.4 秒恰好落在用户继续滚动时占用 MainActor。
    persistTask = Task.detached(priority: .utility) {
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled else { return }
      let defaults = UserDefaults.standard
      defaults.set(fileSidebarWidth, forKey: fileSidebarWidthKey)
      defaults.set(detailPanelWidth, forKey: detailPanelWidthKey)
      defaults.set(isFileSidebarPresented, forKey: isFileSidebarPresentedKey)
    }
  }
}
