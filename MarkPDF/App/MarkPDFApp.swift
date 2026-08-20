import Carbon
import SwiftUI
import os

/// App 委托（v1.5 冷启动时序修复）：SwiftUI 的 onOpenURL 要等首窗渲染后才回调
///（实测比首窗 onAppear 晚约 0.5s），而启动 AppleEvent（odoc）在 willFinishLaunching 后、
/// 首窗出现前就由 NSAppleEventManager 分发——在此直接捕获并喂外部打开路由，
/// 首窗 onAppear 才能凭 hasPendingExternalOpen 跳过工作区恢复
///（否则冷启动双击文件 = 工作区窗口 + 文件窗口两个窗口）。
/// 挂上此处理器后 odoc 不再流向 onOpenURL（保留它作兜底，重复投递由 handle 去重）
final class MarkPDFAppDelegate: NSObject, NSApplicationDelegate {
  /// 由 App 结构体 init 经 wire(_:) 接线（StateObject 持有，App 级单实例）
  static weak var externalOpen: ExternalOpenCoordinator?
  /// 窗口路由中枢（wire 时一并接线）：零活窗复活（激活/点 Dock）走它的编排
  static weak var coordinator: WindowCoordinator?
  /// odoc 可能早于 App 结构体 init 到达（彼时 StateObject 尚未创建）：先暂存，
  /// wire 时补投——补投仍早于首窗 onAppear，恢复决策不受影响
  private static var earlyURLs: [URL] = []

  /// 接线并补投早到的文件（MarkPDFApp.init 调用，必跑主线程）
  static func wire(externalOpen: ExternalOpenCoordinator, windowCoordinator: WindowCoordinator) {
    Self.externalOpen = externalOpen
    Self.coordinator = windowCoordinator
    guard !earlyURLs.isEmpty else { return }
    let pending = earlyURLs
    earlyURLs = []
    MainActor.assumeIsolated {
      for url in pending {
        externalOpen.handle(url)
      }
    }
  }

  /// 接线前暂存（仅 wire 前的极短窗口期会走到）
  static func stashEarly(_ urls: [URL]) {
    earlyURLs.append(contentsOf: urls)
  }

  /// 冷启动场景转发只进行一次（多文件同批到达时，其余文件仍走同步喂入路由）
  private var didForwardInitialScene = false
  /// 启动时 App 处于隐藏状态（open -g / 启动器后台唤起）：SwiftUI 不会建初始窗，
  /// 激活后须补窗。正常启动不会经过此路径
  private var launchedHidden = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSAppleEventManager.shared().setEventHandler(
      self, andSelector: #selector(handleOpenDocumentsEvent(_:reply:)),
      forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments)
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    launchedHidden = NSApp.isHidden
  }

  /// 后台/隐藏启动的补窗：激活时若无任何活窗则恢复工作区现场。
  /// 延迟探测——SwiftUI 亦可能在激活时补建首窗，立即补会撞成双窗
  func applicationDidBecomeActive(_ notification: Notification) {
    guard launchedHidden else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      MainActor.assumeIsolated {
        Self.coordinator?.reviveWindowIfWindowless()
      }
    }
  }

  /// 点 Dock 图标（全部窗口已关 / 后台启动从未建窗）：延迟探测补窗。
  /// 返回 true 保持系统默认（unhide）；SwiftUI 若自建首窗，探测到活窗即不补
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        MainActor.assumeIsolated {
          Self.coordinator?.reviveWindowIfWindowless()
        }
      }
    }
    return true
  }

  /// 向 SwiftUI 内部委托转发 open 事件强制建立初始场景（无活窗时的建窗原语，
  /// 冷启动 odoc 与零活窗复活共用）。带文件 URL 时 onOpenURL 的重复投递
  /// 由外部打开路由幂等吸收；目录 URL 被白名单忽略，仅用建窗副作用
  static func forwardSceneCreation(urls: [URL]) {
    DispatchQueue.main.async {
      let selector = #selector(NSApplicationDelegate.application(_:open:))
      guard let delegate = NSApp.delegate, delegate.responds(to: selector) else { return }
      delegate.application?(NSApp, open: urls)
    }
  }

  /// 打开文档 AppleEvent（'aevt/odoc'）：Finder 双击 / Open With / 拖 Dock，冷热启动同通道。
  /// 直接对象为文件描述符列表，逐项归一成 file URL：
  /// ① 同步喂外部打开路由（首窗 onAppear 才能凭 hasPendingExternalOpen 跳过工作区恢复）
  /// ② 异步转发给 SwiftUI 内部委托走正常流程——挂了这个处理器后 odoc 不再流向
  ///    onOpenURL，不转发则冷启动双击文件时 SwiftUI 连初始窗口都不建（实测零窗口）
  @objc private func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    guard let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
    var urls: [URL] = []
    for index in 1...list.numberOfItems {
      guard
        let urlDesc = list.atIndex(index)?.coerce(toDescriptorType: DescType(typeFileURL)),
        let urlString = String(data: urlDesc.data, encoding: .utf8),
        let url = URL(string: urlString)
      else { continue }
      urls.append(url)
    }
    guard !urls.isEmpty else { return }
    // AppleEvent 处理器跑在主线程；handle 是 @MainActor 隔离，静态断言免异步一跳
    let needsScene = MainActor.assumeIsolated {
      if let externalOpen = MarkPDFAppDelegate.externalOpen {
        for url in urls {
          externalOpen.handle(url)
        }
        return !externalOpen.isReady
      }
      MarkPDFAppDelegate.stashEarly(urls)
      return true
    }
    // 只有冷启动（首窗尚未出现）才转发给 SwiftUI 建初始场景，且只转一次：
    // 暖启动路由已在上面同步完成，再转发会让 SwiftUI 多空一个默认窗口（实测）
    guard needsScene, !didForwardInitialScene else { return }
    didForwardInitialScene = true
    Self.forwardSceneCreation(urls: urls)
  }
}

@main
struct MarkPDFApp: App {
  @NSApplicationDelegateAdaptor(MarkPDFAppDelegate.self) private var appDelegate
  // 共享层（App 级，跨窗口单实例）：设置/密钥/收藏/最近/阅读位置/快照存储/窗口注册表。
  // 每窗口状态（工作区/标签/阅读/标注/AI 会话）在 WindowSession（WindowRootView 持有）
  @StateObject private var settingsStore = SettingsStore()
  @StateObject private var favoritesStore = FavoritesStore()
  @StateObject private var recentsStore = RecentFilesStore()
  @StateObject private var readingPositionStore = PDFReadingPositionStore()
  // 默认打开方式开关（设置 → 通用）
  @StateObject private var defaultHandlerService = DefaultHandlerService()
  // Finder 直接打开文件的路由（文档类型见 Info.plist CFBundleDocumentTypes）
  @StateObject private var externalOpen: ExternalOpenCoordinator
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
    // 显式局部实例再包 StateObject（与其他 store 同 pattern）：
    // 内联 = 写法在 init 里读 wrappedValue 拿到的是 thunk 临时实例，
    // 视图图安装时另建实例——wire 给委托的弱引用随即悬垂
    let externalOpen = ExternalOpenCoordinator()
    _aiSettingsStore = StateObject(wrappedValue: aiSettingsStore)
    _aiKeyStore = StateObject(wrappedValue: aiKeyStore)
    _snapshotStore = StateObject(wrappedValue: snapshotStore)
    _aiSessionRepository = StateObject(wrappedValue: aiSessions)
    _windowCoordinator = StateObject(wrappedValue: coordinator)
    _externalOpen = StateObject(wrappedValue: externalOpen)
    MarkPDFAppDelegate.wire(externalOpen: externalOpen, windowCoordinator: coordinator)
    // 零活窗复活（B1）：恢复编排读快照存储；openWindow 动作不可用时以
    // 「向 SwiftUI 转发 open 事件」建初始场景（与冷启动 odoc 同款原语）
    coordinator.snapshotStore = snapshotStore
    coordinator.requestSceneCreation = { urls in
      MarkPDFAppDelegate.forwardSceneCreation(urls: urls)
    }
    // 开着的工作区窗口清单：开窗/切工作区/关窗即落盘（点 × 不是退出，进程仍活着——
    // 只在退出时采集会让清单停在上一次退出的旧状态，重新激活时把早已关掉的工作区开回来）
    coordinator.onOpenWindowRootsChanged = { roots in
      snapshotStore.recordOpenWindowRoots(roots)
    }
    // 退出前兜底落盘（FR-2.7 全部标签 + FR-4.6 标注写回 + FR-1.6 快照 + AI 会话）：
    // 红钮关窗后再 ⌘Q 时视图已销毁、无人接收通知——挂 App 级，逐窗口 flush + 共享存储 flush
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { _ in
      // 定格窗口清单（此后关窗不再改写：退出流程逐个关窗会把清单洗空）+ 逐窗口 flush
      coordinator.prepareForTermination()
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
        recentsStore: recentsStore,
        favoritesStore: favoritesStore
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
      // Finder 双击 / Open With / 拖 Dock 打开文件：恢复现场就绪前入队，就绪后路由。
      // 主通道是 AppDelegate 的 odoc AppleEvent 处理器（冷启动时序），此处作兜底
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
