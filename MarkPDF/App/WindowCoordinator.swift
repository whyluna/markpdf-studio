import AppKit
import Foundation
import os

/// 窗口注册表与路由中枢（v1.5 多窗口，App 级）：
/// 「已打开则聚焦、否则开新窗」——外部打开的文件与各工作区互不干扰。
/// 新窗口请求走 FIFO 队列（openWindow 无法传值；新窗口根视图首次出现时领取）
@MainActor
final class WindowCoordinator: ObservableObject {
  /// 新窗口的初始任务
  enum WindowRequest: Equatable {
    /// 打开工作区（含现场恢复）
    case workspace(URL)
    /// 恢复上次开着的工作区窗口（走书签取沙盒授权，v1.5 重启恢复）
    case restoreWorkspace(rootPath: String)
    /// 仅打开单个文件（无工作区，侧栏空态）
    case file(URL)
    /// 打开工作区并在其中打开该文件（外部打开后接受「设为工作区」）
    case workspaceWithFile(root: URL, file: URL)
  }

  /// 路由判定（纯函数可单测）
  enum RouteDecision: Equatable {
    /// 目标已有窗口：聚焦它（openTab 为待打开的文件，nil 表示只聚焦）
    case focusExisting(windowIndex: Int, openTab: URL?)
    /// 新开窗口
    case newWindow(WindowRequest)
  }

  /// 窗口的路由快照（纯函数入参；避免路由逻辑触碰 store）
  struct WindowInfo: Equatable {
    var rootPath: String?
    /// 该窗口已打开的文件（符号链接归一后的绝对路径）
    var openFilePaths: [String] = []
  }

  private(set) var sessions: [WindowSession] = []
  /// 待领取的新窗口任务（FIFO）
  private var requests: [WindowRequest] = []
  /// 由窗口根视图注入的 openWindow 动作（SwiftUI 环境值只能在视图层取）
  var openNewWindow: (() -> Void)?
  /// 活窗工作区清单变化回调（关窗/开窗即落盘；App 层接线到快照存储）
  var onOpenWindowRootsChanged: (([String]) -> Void)?
  /// 退出流程中（willTerminate 已到）：此后关窗不再改写窗口清单——
  /// ⌘Q 的顺序是 willTerminate 写入完整清单 → 窗口逐个关闭，
  /// 若放任关窗事件改写，清单会被洗空，「退出后恢复全部窗口」失效
  private(set) var isTerminating = false

  // MARK: - 注册

  /// 登记窗口 session（幂等）；返回是否首个窗口（首窗负责启动恢复与外部打开接线）
  @discardableResult
  func register(_ session: WindowSession) -> Bool {
    if let index = sessions.firstIndex(where: { $0 === session }) {
      return index == 0
    }
    sessions.append(session)
    Logger.workspace.info("窗口登记: 共 \(self.sessions.count) 个")
    return sessions.count == 1
  }

  func unregister(_ session: WindowSession) {
    sessions.removeAll { $0 === session }
    // 关窗即更新清单（点 × 不是退出：进程仍活着，点 Dock 图标重开窗口时
    // 读的是磁盘清单——只在退出时采集会让它停在上一次退出的旧状态，
    // 把早已关掉的工作区又开回来，实测）
    publishOpenWindowRoots()
  }

  /// 工作区根清单落盘（退出流程中不动，见 isTerminating）
  func publishOpenWindowRoots() {
    guard !isTerminating else { return }
    onOpenWindowRootsChanged?(workspaceRoots())
  }

  /// 当前活窗的工作区根（顺序即窗口顺序；单文件窗口无根，不占位）
  func workspaceRoots() -> [String] {
    sessions.compactMap { $0.stateStore.currentRootPath }
  }

  /// 退出前兜底：定格窗口清单（此后关窗不再改写）+ 逐窗口落盘
  func prepareForTermination() {
    onOpenWindowRootsChanged?(workspaceRoots())
    isTerminating = true
    flushAll()
  }

  /// 退出前兜底：逐窗口落盘（标签/标注/快照/AI 会话）
  func flushAll() {
    for session in sessions {
      session.flush()
    }
  }

  // MARK: - 新窗口任务队列

  /// 请求开新窗口（任务入队 + 触发 openWindow；新窗根视图 onAppear 领取）
  func requestWindow(_ request: WindowRequest) {
    requests.append(request)
    guard let openNewWindow else {
      Logger.workspace.error("openWindow 未接线，新窗口请求丢弃: \(String(describing: request), privacy: .public)")
      requests.removeLast()
      return
    }
    openNewWindow()
  }

  /// 新窗口领取任务（无任务返回 nil——系统窗口恢复多开的窗口显示空态）
  func takePendingRequest() -> WindowRequest? {
    guard !requests.isEmpty else { return nil }
    return requests.removeFirst()
  }

  /// 外部打开的文件被接受「设为工作区」：把承接它的窗口升级为工作区窗口。
  /// 新窗口可能还在队列里（未出现）也可能已领取任务出现——两种时序都要覆盖
  func upgradeExternalFileWindow(to root: URL, file: URL) {
    let path = Self.normalize(file)
    if let index = requests.firstIndex(where: { $0 == .file(file) }) {
      requests[index] = .workspaceWithFile(root: root, file: file)
      return
    }
    if let session = sessions.first(where: { session in
      session.stateStore.currentRootPath == nil
        && session.tabStore.groups.contains { group in
          group.tabs.contains { $0.url.map(Self.normalize) == path }
        }
    }) {
      session.openWorkspaceInPlace(root)
      session.tabStore.open(url: file)
      focus(session)
      return
    }
    requestWindow(.workspaceWithFile(root: root, file: file))
  }

  // MARK: - 路由

  /// 当前窗口快照（路由入参）
  func windowInfos() -> [WindowInfo] {
    sessions.map { session in
      WindowInfo(
        rootPath: session.stateStore.currentRootPath,
        openFilePaths: session.tabStore.groups.flatMap { group in
          group.tabs.compactMap { $0.url.map(Self.normalize) }
        }
      )
    }
  }

  /// 外部打开一个文件的路由（纯函数）：
  /// ① 该文件已在某窗口打开 → 聚焦（不重复开，避免同文件双窗口的标注/编辑器冲突）
  /// ② 某窗口工作区包含该文件 → 聚焦并在其中开标签（沿用「同工作区直接开标签」语义）
  /// ③ 无工作区且未开任何文件的空窗口 → 就地承接（冷启动单文件打开不残留空窗口；
  ///    欢迎草稿不算内容，承接前由 TabStore 关掉未触碰的草稿）
  /// ④ 否则新开单文件窗口（与现有工作区完全隔离）
  nonisolated static func routeExternalFile(_ file: URL, windows: [WindowInfo]) -> RouteDecision {
    let path = normalize(file)
    if let index = windows.firstIndex(where: { $0.openFilePaths.contains(path) }) {
      return .focusExisting(windowIndex: index, openTab: nil)
    }
    if let index = windows.firstIndex(where: { info in
      guard let rootPath = info.rootPath else { return false }
      return file.isWithinWorkspace(rootPath: rootPath)
    }) {
      return .focusExisting(windowIndex: index, openTab: file)
    }
    if let index = windows.firstIndex(where: { $0.rootPath == nil && $0.openFilePaths.isEmpty }) {
      return .focusExisting(windowIndex: index, openTab: file)
    }
    return .newWindow(.file(file))
  }

  /// 打开工作区的路由（纯函数）：
  /// ① 目标工作区已有窗口 → 聚焦（不重复开同一工作区，规避双窗口写同一槽位）
  /// ② 请求窗口自身还没有工作区 → 就地打开（空窗口不浪费）
  /// ③ 否则新开工作区窗口（当前窗口原样不动）
  nonisolated static func routeWorkspace(_ folder: URL, windows: [WindowInfo], requestingIndex: Int?) -> RouteDecision {
    let target = folder.standardizedFileURL.path
    if let index = windows.firstIndex(where: { $0.rootPath == target }) {
      return .focusExisting(windowIndex: index, openTab: nil)
    }
    if let requestingIndex, windows.indices.contains(requestingIndex),
      windows[requestingIndex].rootPath == nil
    {
      return .focusExisting(windowIndex: requestingIndex, openTab: nil)
    }
    return .newWindow(.workspace(folder))
  }

  /// 执行外部文件路由（生产入口）
  func handleExternalFile(_ file: URL) {
    let decision = Self.routeExternalFile(file, windows: windowInfos())
    Logger.workspace.info("外部打开路由: \(file.lastPathComponent, privacy: .public) → \(String(describing: decision), privacy: .public)")
    apply(decision, fallbackOpen: file)
  }

  /// 执行「打开工作区」路由（生产入口）；requesting 为发起窗口
  func handleOpenWorkspace(_ folder: URL, requesting: WindowSession?) {
    let index = requesting.flatMap { session in sessions.firstIndex { $0 === session } }
    let decision = Self.routeWorkspace(folder, windows: windowInfos(), requestingIndex: index)
    Logger.workspace.info("打开工作区路由: \(folder.lastPathComponent, privacy: .public) → \(String(describing: decision), privacy: .public)")
    switch decision {
    case .focusExisting(let windowIndex, _):
      guard sessions.indices.contains(windowIndex) else { return }
      let session = sessions[windowIndex]
      if session.stateStore.currentRootPath == nil {
        session.openWorkspaceInPlace(folder)
      }
      focus(session)
    case .newWindow(let request):
      requestWindow(request)
    }
  }

  private func apply(_ decision: RouteDecision, fallbackOpen file: URL) {
    switch decision {
    case .focusExisting(let windowIndex, let openTab):
      guard sessions.indices.contains(windowIndex) else { return }
      let session = sessions[windowIndex]
      if let openTab {
        session.tabStore.open(url: openTab)
      }
      focus(session)
    case .newWindow(let request):
      requestWindow(request)
    }
  }

  func focus(_ session: WindowSession) {
    session.window?.makeKeyAndOrderFront(nil)
  }

  /// 路径归一（符号链接 + 标准化）：同一文件不同路径形态视为同一个
  nonisolated static func normalize(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}
