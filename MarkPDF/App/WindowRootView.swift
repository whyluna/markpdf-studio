import AppKit
import SwiftUI

/// 窗口根视图（v1.5 多窗口）：每个窗口 scene 一个 WindowSession（per-window store 全家），
/// 在此注入 environmentObject——视图层 @EnvironmentObject 声明零改动。
/// 共享 store（设置/密钥/收藏/最近/阅读位置等）由 App 在外层注入
struct WindowRootView: View {
  @StateObject private var session: WindowSession
  @Environment(\.openWindow) private var openWindow
  private let coordinator: WindowCoordinator
  private let externalOpen: ExternalOpenCoordinator
  private let recentsStore: RecentFilesStore

  init(
    coordinator: WindowCoordinator,
    snapshotStore: WorkspaceSnapshotStore,
    aiSettings: AISettingsStore,
    aiKeys: AIKeyStore,
    aiSessions: AISessionRepository,
    externalOpen: ExternalOpenCoordinator,
    recentsStore: RecentFilesStore
  ) {
    self.coordinator = coordinator
    self.externalOpen = externalOpen
    self.recentsStore = recentsStore
    _session = StateObject(
      wrappedValue: WindowSession(
        snapshotStore: snapshotStore,
        aiSettings: aiSettings,
        aiKeys: aiKeys,
        aiSessions: aiSessions
      )
    )
  }

  var body: some View {
    ContentView()
      .environmentObject(session)
      .environmentObject(session.workspaceStore)
      .environmentObject(session.tabStore)
      .environmentObject(session.pdfStore)
      .environmentObject(session.pdfBookmarksStore)
      .environmentObject(session.imageStore)
      .environmentObject(session.annotationStore)
      .environmentObject(session.searchStore)
      .environmentObject(session.backlinksStore)
      .environmentObject(session.stateStore)
      .environmentObject(session.aiChatStore)
      .background(
        WindowAccessor { window in
          guard session.window !== window else { return }
          session.window = window
          // 关窗即落盘本窗现场并注销（红钮关窗后 ⌘Q 时视图已销毁，无人接收）
          NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
          ) { _ in
            MainActor.assumeIsolated {
              session.flush()
              coordinator.unregister(session)
            }
          }
        }
      )
      .onAppear(perform: setUpWindow)
  }

  private func setUpWindow() {
    let isFirst = coordinator.register(session)
    session.coordinator = coordinator
    session.wireUp(recentsStore: recentsStore)
    // openWindow 只能在视图层取（环境值）：注入给路由中枢开新窗口
    coordinator.openNewWindow = { openWindow(id: WindowRootView.groupID) }
    // 新窗口领取初始任务（工作区 / 单文件 / 工作区+文件）；无任务则空态
    if let request = coordinator.takePendingRequest() {
      session.apply(request)
      return
    }
    guard isFirst else { return }
    // 首窗启动编排（④ 扩展为多工作区窗口恢复）：
    // 冷启动由 Finder 外部打开唤起（队列里有待路由文件）→ 跳过工作区现场恢复
    //（侧栏空态、标签只放外部文件）；否则恢复上次工作区与标签。
    // 顺序不可换：restoreWorkspace 先建立沙盒授权，restoreTabs 读文件先于授权必 EPERM
    if !externalOpen.hasPendingExternalOpen {
      session.stateStore.restoreWorkspace(into: session.workspaceStore)
      session.stateStore.restoreTabs(into: session.tabStore)
    }
    wireExternalOpen()
    externalOpen.markReady()
  }

  /// 外部打开接线（首窗一次，全部指向路由中枢而非具体窗口）
  private func wireExternalOpen() {
    externalOpen.openFileTab = { [coordinator] url in
      coordinator.handleExternalFile(url)
    }
    externalOpen.workspaceRootPaths = { [coordinator] in
      coordinator.windowInfos().compactMap(\.rootPath)
    }
    externalOpen.upgradeToWorkspace = { [coordinator] root, file in
      coordinator.upgradeExternalFileWindow(to: root, file: file)
    }
  }

  /// WindowGroup 的 scene id（openWindow 开同款窗口）
  static let groupID = "workspace"
}

/// 解析本视图所属的 NSWindow（SwiftUI 无窗口句柄 API；聚焦/列宽/关窗 flush 需要）
private struct WindowAccessor: NSViewRepresentable {
  let onResolve: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window {
        onResolve(window)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      if let window = nsView.window {
        onResolve(window)
      }
    }
  }
}
