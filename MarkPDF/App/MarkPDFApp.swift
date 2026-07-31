import SwiftUI
import os

@main
struct MarkPDFApp: App {
  // 共享层（App 级，跨窗口单实例）：设置/密钥/收藏/最近/阅读位置/快照存储/窗口注册表。
  // 每窗口状态（工作区/标签/阅读/标注/AI 会话）在 WindowSession（WindowRootView 持有）
  @StateObject private var settingsStore = SettingsStore()
  @StateObject private var favoritesStore = FavoritesStore()
  @StateObject private var recentsStore = RecentFilesStore()
  @StateObject private var readingPositionStore = PDFReadingPositionStore()
  // 默认打开方式开关（设置 → 通用）
  @StateObject private var defaultHandlerService = DefaultHandlerService()
  // Finder 直接打开文件的路由（文档类型见 Info.plist CFBundleDocumentTypes）
  @StateObject private var externalOpen = ExternalOpenCoordinator()
  // AI（FR-AI.4）：偏好与密钥均为 App 级单例（设置页 / 划词翻译 / AI 助手共用；init 内构建）
  @StateObject private var aiSettingsStore: AISettingsStore
  @StateObject private var aiKeyStore: AIKeyStore
  // 工作区快照单一写者（v1.5 多窗口：各窗口 facade 共享槽位表，防整体互相覆盖）
  @StateObject private var snapshotStore: WorkspaceSnapshotStore
  // AI 会话仓库（v1.5：全部线程集中存全局文件，磁盘唯一写者）
  @StateObject private var aiSessionRepository: AISessionRepository
  @StateObject private var windowCoordinator: WindowCoordinator

  init() {
    let aiSettingsStore = AISettingsStore()
    let aiKeyStore = AIKeyStore()
    let snapshotStore = WorkspaceSnapshotStore()
    let aiSessions = AISessionRepository()
    let coordinator = WindowCoordinator()
    _aiSettingsStore = StateObject(wrappedValue: aiSettingsStore)
    _aiKeyStore = StateObject(wrappedValue: aiKeyStore)
    _snapshotStore = StateObject(wrappedValue: snapshotStore)
    _aiSessionRepository = StateObject(wrappedValue: aiSessions)
    _windowCoordinator = StateObject(wrappedValue: coordinator)
    // 退出前兜底落盘（FR-2.7 全部标签 + FR-4.6 标注写回 + FR-1.6 快照 + AI 会话）：
    // 红钮关窗后再 ⌘Q 时视图已销毁、无人接收通知——挂 App 级，逐窗口 flush + 共享存储 flush
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { _ in
      coordinator.flushAll()
      snapshotStore.flush()
      aiSessions.flush()
    }
  }

  var body: some Scene {
    WindowGroup(id: WindowRootView.groupID) {
      WindowRootView(
        coordinator: windowCoordinator,
        snapshotStore: snapshotStore,
        aiSettings: aiSettingsStore,
        aiKeys: aiKeyStore,
        aiSessions: aiSessionRepository,
        externalOpen: externalOpen,
        recentsStore: recentsStore
      )
      .environmentObject(settingsStore)
      .environmentObject(favoritesStore)
      .environmentObject(recentsStore)
      .environmentObject(readingPositionStore)
      .environmentObject(aiSettingsStore)
      .environmentObject(aiKeyStore)
      .environmentObject(externalOpen)
      .environmentObject(windowCoordinator)
      .frame(minWidth: 1080, minHeight: 640)
      // Finder 双击 / Open With / 拖 Dock 打开文件：恢复现场就绪前入队，就绪后路由
      .onOpenURL { url in
        externalOpen.handle(url)
      }
    }
    .defaultSize(width: 1380, height: 900)
    // 菜单命令经 FocusedValue 路由到焦点窗口（v1.5 多窗口）
    .commands {
      AppCommands()
    }

    // 设置（FR-7.2；⌘,）
    Settings {
      SettingsView()
        .environmentObject(settingsStore)
        .environmentObject(aiSettingsStore)
        .environmentObject(aiKeyStore)
        .environmentObject(defaultHandlerService)
    }
  }
}
