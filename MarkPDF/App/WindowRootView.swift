import AppKit
import SwiftUI

/// 窗口根视图（v1.5 多窗口）：每个窗口 scene 一个 WindowSession（per-window store 全家），
/// 在此注入 environmentObject——视图层 @EnvironmentObject 声明零改动。
/// 共享 store（设置/密钥/收藏/最近/阅读位置等）由 App 在外层注入
struct WindowRootView: View {
  @StateObject private var session: WindowSession
  private let coordinator: WindowCoordinator
  private let externalOpen: ExternalOpenCoordinator
  private let recentsStore: RecentFilesStore

  init(
    coordinator: WindowCoordinator,
    snapshotStore: WorkspaceSnapshotStore,
    aiSettings: AISettingsStore,
    aiKeys: AIKeyStore,
    externalOpen: ExternalOpenCoordinator,
    recentsStore: RecentFilesStore
  ) {
    self.coordinator = coordinator
    self.externalOpen = externalOpen
    self.recentsStore = recentsStore
    _session = StateObject(
      wrappedValue: WindowSession(snapshotStore: snapshotStore, aiSettings: aiSettings, aiKeys: aiKeys)
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
          session.window = window
        }
      )
      .onAppear {
        let isFirst = coordinator.register(session)
        session.wireUp(recentsStore: recentsStore)
        guard isFirst else { return }
        // 首窗启动编排（保持单窗口时代行为；④ 扩展为多工作区窗口恢复）：
        // 冷启动由 Finder 外部打开唤起（队列里有待路由文件）→ 跳过工作区现场恢复
        //（侧栏空态、标签只放外部文件）；否则恢复上次工作区与标签。
        // 顺序不可换：restoreWorkspace 先建立沙盒授权，restoreTabs 读文件先于授权必 EPERM
        if !externalOpen.hasPendingExternalOpen {
          session.stateStore.restoreWorkspace(into: session.workspaceStore)
          session.stateStore.restoreTabs(into: session.tabStore)
        }
        // Finder 直接打开文件（授权已建立、标签现场已恢复后才放行队列）
        session.wireExternalOpen(externalOpen)
        externalOpen.markReady()
      }
  }
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
