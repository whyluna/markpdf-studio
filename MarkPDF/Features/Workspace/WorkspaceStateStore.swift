import Foundation
import os

/// 工作区状态持久化（FR-1.6）：per-window facade（v1.5 多窗口）——
/// 快照/书签/落盘由 App 级 WorkspaceSnapshotStore 单一持有（多窗口共享槽位表不互相覆盖），
/// 本类只保留窗口态（currentRootPath / pendingSwitchPath / 安全作用域访问权）与编排逻辑。
/// 标签现场按工作区隔离：切换工作区时旧现场存槽、新工作区现场恢复（FR-1.6 增强）。
/// PDF 阅读位置由 PDFReadingPositionStore 单独持久化（FR-3.5），不在此快照内。
@MainActor
final class WorkspaceStateStore: ObservableObject {
  typealias TabState = WorkspaceSnapshotStore.TabState
  typealias WorkspaceSnapshot = WorkspaceSnapshotStore.WorkspaceSnapshot
  typealias Snapshot = WorkspaceSnapshotStore.Snapshot

  private let store: WorkspaceSnapshotStore
  /// 当前工作区根路径（tabsDidChange 的槽位 key；nil 表示尚无工作区）
  private(set) var currentRootPath: String?
  /// 切换工作区的目标路径（切换编排期间，watcher 仍以旧 root 触发 workspaceDidChange，
  /// 必须忽略——否则槽位指针被拉回旧工作区，随后的 replaceAll 把空白草稿写进旧槽、清掉真实标签）
  private var pendingSwitchPath: String?
  /// 启动恢复的目标路径（恢复编排期间 root 尚未异步就绪，collapsedFolders/AI 显隐赋值的
  /// 路过事件会以 nil root 触发 workspaceDidChange，必须把 currentRootPath 保住房瞬态打回
  /// nil——否则该窗口期内外部打开路由误判异根，开多余裸窗/弹「设为工作区」）
  private var pendingRestorePath: String?
  /// 恢复时取得的安全作用域资源（保持访问至进程结束，否则工作区授权失效）
  private var accessedRootURL: URL?

  /// 多窗口共享快照存储注入（App 级唯一实例）
  init(snapshotStore: WorkspaceSnapshotStore) {
    store = snapshotStore
  }

  /// 单窗口/测试便捷入口：自建私有快照存储（语义与旧版单例一致）
  convenience init(defaults: UserDefaults = .standard) {
    self.init(snapshotStore: WorkspaceSnapshotStore(defaults: defaults))
  }

  // MARK: - 状态记录（各 Store 变化时调用）

  /// 标签结构变化（开/关/移动/分栏/激活切换）：写入当前工作区槽位
  func tabsDidChange(groups: [TabGroup], activeGroupID: TabGroup.ID) {
    guard let rootPath = currentRootPath else { return }  // 无工作区不入槽
    var ws = store.state.workspaces[rootPath] ?? WorkspaceSnapshot()
    // FR-7.4 审查修复：异根文件标签（Finder 裸开）不入当前工作区槽位——否则旧槽被污染：
    // 接受「设为工作区」时异根路径留在旧槽；选「仅打开文件」时留在旧槽且重启后
    // Finder 授权失效，恢复必 EPERM。nil url 草稿不受影响照常记录。
    //（判定与 ExternalOpenCoordinator.decide 共用，见 isWithinWorkspace 注释）
    ws.groups = groups.map { group in
      group.tabs.compactMap { tab in
        guard let url = tab.url else { return TabState(path: nil, kind: tab.kind.rawValue) }
        guard url.isWithinWorkspace(rootPath: rootPath) else { return nil }
        return TabState(path: url.path, kind: tab.kind.rawValue)
      }
    }
    // 激活标签同理：异根激活标签记为 nil（恢复时回退组内首个），不得记录异根路径
    ws.activeTabs = groups.map { group in
      guard let url = group.activeTab?.url, url.isWithinWorkspace(rootPath: rootPath) else { return nil }
      return url.path
    }
    ws.activeGroup = groups.firstIndex { $0.id == activeGroupID } ?? 0
    store.state.workspaces[rootPath] = ws
    store.schedulePersist()
  }

  /// 槽位 key 统一标准化（/tmp→/private/tmp 等符号链接归一，防止同一文件夹两个 key）
  private func slotKey(for url: URL) -> String {
    url.standardizedFileURL.path
  }

  /// 工作区变化（打开新文件夹 / 折叠态变化 / AI 助手显隐）：根目录存 security-scoped bookmark
  func workspaceDidChange(root: URL?, collapsedFolders: Set<URL>, aiAssistantVisible: Bool = false) {
    // 切换/恢复编排期间：watcher 上报的还是旧 root（异步扫描未完成）或折叠态赋值的
    // 路过事件，一律忽略——否则槽位指针被拉回旧工作区/瞬态打回 nil
    if let pending = pendingSwitchPath {
      guard let root, slotKey(for: root) == pending else { return }
      pendingSwitchPath = nil  // 新 root 到达，切换落定，走正常流程
      pendingRestorePath = nil  // 切换目标已变，恢复期的守卫一并失效
    } else if let pending = pendingRestorePath {
      guard let root, slotKey(for: root) == pending else { return }
      pendingRestorePath = nil  // 恢复的 root 到达，落定
    }
    if let root {
      let key = slotKey(for: root)
      currentRootPath = key
      store.state.lastRootPath = key
      if let bookmark = try? root.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      ) {
        // 逐工作区书签（v1.5）：重启可恢复多个工作区窗口
        store.state.bookmarks[key] = bookmark
      }
      var ws = store.state.workspaces[key] ?? WorkspaceSnapshot()
      ws.collapsedFolders = collapsedFolders.map(\.path).sorted()
      ws.aiAssistantVisible = aiAssistantVisible
      store.state.workspaces[key] = ws
    } else {
      currentRootPath = nil
    }
    store.schedulePersist()
  }

  /// md 光标行记录（内核 500ms 防抖上报）
  func recordCursor(url: URL, line: Int) {
    store.state.cursorLines[url.path] = line
    store.schedulePersist()
  }

  /// 某 md 文件的上次光标行（载入恢复用）
  func cursorLine(for url: URL) -> Int? {
    store.state.cursorLines[url.path]
  }

  /// 工作区根被改名/移动（Finder 等外部途径）：restoreWorkspace 解析书签发现
  /// 「解析出的真实路径 ≠ 查找用的存储键」时触发——快照内部槽位换键后，
  /// 经此钩子通知外部存储（AI 会话/最近打开/收藏）一起平移（WindowSession 接线）
  var onWorkspaceRootMoved: ((String, String) -> Void)?

  // MARK: - 启动恢复

  /// 恢复标签组与激活状态（当前工作区槽位的现场；一般在 restoreWorkspace 之后调用，
  /// 授权失败时回退 lastRootPath，保持与 v1「无工作区也恢复标签」一致的行为）
  func restoreTabs(into tabStore: TabStore) {
    guard let rootPath = currentRootPath ?? store.state.lastRootPath,
      let ws = store.state.workspaces[rootPath] else { return }
    tabStore.restore(
      tabStates: ws.groups,
      activeTabPaths: ws.activeTabs,
      activeGroupIndex: ws.activeGroup
    )
  }

  /// 恢复工作区：解析 bookmark → 取得安全作用域访问权 → 打开文件夹 → 恢复折叠态。
  /// rootPath 为 nil 时恢复最后使用的工作区；无对应书签则回退 v1 旧单书签（解析后收敛进多书签表）
  func restoreWorkspace(into workspaceStore: WorkspaceStore, rootPath: String? = nil) {
    let targetPath = rootPath ?? store.state.lastRootPath
    let bookmark = targetPath.flatMap { store.state.bookmarks[$0] } ?? store.state.rootBookmark
    guard let bookmark else { return }
    var isStale = false
    guard let url = try? URL(
      resolvingBookmarkData: bookmark,
      options: .withSecurityScope,
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ), url.startAccessingSecurityScopedResource() else {
      Logger.workspace.error("工作区 bookmark 恢复失败（授权失效或文件夹已移动）")
      return
    }
    // 不调用 stopAccessing：访问权需保持到进程结束（扫描/监听/文件操作都依赖它）
    accessedRootURL = url
    let key = slotKey(for: url)
    // 根被改名/移动：书签按文件 ID 解析到新路径，与查找用的存储键不一致 →
    // 槽位整体迁移（现场/书签/光标行/窗口清单），外部存储经钩子一起平移
    if let targetPath, targetPath != key {
      migrateRootSlot(from: targetPath, to: key)
    }
    currentRootPath = key
    store.state.lastRootPath = key
    // 恢复编排保护：openFolder 是异步扫描，随后的 collapsedFolders/AI 显隐赋值会以
    // nil root 路过 workspaceDidChange——在此登记目标，root 到达前的路过事件一律忽略
    pendingRestorePath = key
    // 格式收敛：v1 单书签解析出真实路径后归入多书签表
    if store.state.bookmarks[key] == nil {
      store.state.bookmarks[key] = bookmark
      store.state.rootBookmark = nil
      store.schedulePersist()
    }
    migrateLegacySnapshotIfNeeded(forRoot: key)
    workspaceStore.openFolder(url)
    let ws = store.state.workspaces[key]
    workspaceStore.collapsedFolders = Set((ws?.collapsedFolders ?? []).map { URL(fileURLWithPath: $0) })
    workspaceStore.isAIAssistantPresented = ws?.aiAssistantVisible ?? false
  }

  // MARK: - 切换工作区

  /// 切换工作区（⌘O 打开新文件夹）：旧现场已随 tabsDidChange 增量入槽 →
  /// 落盘未保存编辑 → 打开新文件夹 → 恢复新工作区自己的标签现场（无记录则空白草稿）。
  /// 重开当前工作区为 no-op（不清空标签）。
  func switchWorkspace(to url: URL, workspaceStore: WorkspaceStore, tabStore: TabStore) {
    let target = url.standardizedFileURL
    if target.path == currentRootPath { return }
    tabStore.flushAll()
    // 同步更新槽位指针：root 是后台扫描完成才异步赋值的，若不先改，
    // 随后 replaceAll 触发的 tabsDidChange 会把新现场错写进旧槽。
    // pendingSwitchPath 挡住期间 watcher 以旧 root 触发的 workspaceDidChange 回写
    currentRootPath = target.path
    store.state.lastRootPath = target.path
    pendingSwitchPath = target.path
    workspaceStore.openFolder(target)
    if let ws = store.state.workspaces[target.path] {
      workspaceStore.collapsedFolders = Set(ws.collapsedFolders.map { URL(fileURLWithPath: $0) })
      workspaceStore.isAIAssistantPresented = ws.aiAssistantVisible ?? false
      tabStore.replaceAll(tabStates: ws.groups, activeTabPaths: ws.activeTabs, activeGroupIndex: ws.activeGroup)
    } else {
      workspaceStore.collapsedFolders = []
      workspaceStore.isAIAssistantPresented = false
      tabStore.replaceAll(tabStates: [], activeTabPaths: [], activeGroupIndex: 0)
    }
  }

  /// 根改名/移动的槽位迁移（纯函数可单测）：槽位键、书签键、最后根、窗口清单换键；
  /// 槽位内部（标签/激活/折叠）与光标行表里的绝对路径按前缀平移
  nonisolated static func migrateRootSlot(
    _ state: inout WorkspaceSnapshotStore.Snapshot, from oldPath: String, to newPath: String
  ) {
    func shifted(_ path: String) -> String {
      RecentFilesStore.shift(path, from: oldPath, to: newPath)
    }
    if var ws = state.workspaces.removeValue(forKey: oldPath) {
      if state.workspaces[newPath] == nil {
        ws.collapsedFolders = ws.collapsedFolders.map(shifted)
        ws.groups = ws.groups.map { group in
          group.map { WorkspaceSnapshotStore.TabState(path: $0.path.map(shifted), kind: $0.kind) }
        }
        ws.activeTabs = ws.activeTabs.map { $0.map(shifted) }
        state.workspaces[newPath] = ws
      }
    }
    if let bookmark = state.bookmarks.removeValue(forKey: oldPath),
      state.bookmarks[newPath] == nil
    {
      state.bookmarks[newPath] = bookmark
    }
    if state.lastRootPath == oldPath {
      state.lastRootPath = newPath
    }
    state.openWindowRoots = state.openWindowRoots.map(shifted)
    var cursorLines: [String: Int] = [:]
    for (path, line) in state.cursorLines {
      cursorLines[shifted(path)] = line
    }
    state.cursorLines = cursorLines
  }

  /// 实例侧迁移：换键后落盘 + 通知外部存储（AI 会话/最近打开/收藏）一起平移
  private func migrateRootSlot(from oldPath: String, to newPath: String) {
    Self.migrateRootSlot(&store.state, from: oldPath, to: newPath)
    store.schedulePersist()
    Logger.workspace.info(
      "工作区根改名/移动，槽位迁移: \(oldPath, privacy: .public) → \(newPath, privacy: .public)")
    onWorkspaceRootMoved?(oldPath, newPath)
  }

  /// v1 快照迁移：旧的全局标签组归入「最后工作区」槽位（迁移后即清空遗留字段，只执行一次）
  private func migrateLegacySnapshotIfNeeded(forRoot rootPath: String) {
    guard store.state.workspaces[rootPath] == nil, !store.state.groups.isEmpty else { return }
    store.state.workspaces[rootPath] = WorkspaceSnapshot(
      collapsedFolders: store.state.collapsedFolders,
      groups: store.state.groups,
      activeTabs: store.state.activeTabs,
      activeGroup: store.state.activeGroup
    )
    // 迁移完成后清空遗留字段，避免重复迁移
    store.state.groups = []
    store.state.activeTabs = []
    store.state.collapsedFolders = []
    store.state.activeGroup = 0
  }

  // MARK: - 落盘

  /// 立即落盘挂起的快照（退出前调用）
  func flush() {
    store.flush()
  }
}
