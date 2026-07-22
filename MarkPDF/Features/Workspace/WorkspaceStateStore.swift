import Foundation
import os

/// 工作区状态持久化（FR-1.6）：快照存 UserDefaults（JSON），0.5s 防抖落盘，启动恢复现场。
/// 快照内容：最后工作区根（security-scoped bookmark）、各工作区的标签组/折叠态（按根路径分槽）、md 光标行。
/// 标签现场按工作区隔离：切换工作区时旧现场存槽、新工作区现场恢复（FR-1.6 增强）。
/// PDF 阅读位置由 PDFReadingPositionStore 单独持久化（FR-3.5），不在此快照内。
@MainActor
final class WorkspaceStateStore: ObservableObject {
  /// 单个标签的快照（path 为 nil 表示未命名草稿）
  struct TabState: Codable, Equatable {
    var path: String?
    var kind: String
  }

  /// 单个工作区的现场（标签组 + 折叠态）
  struct WorkspaceSnapshot: Codable, Equatable {
    var collapsedFolders: [String] = []
    var groups: [[TabState]] = []
    /// 各组激活标签路径（草稿激活为 nil）
    var activeTabs: [String?] = []
    var activeGroup: Int = 0
  }

  struct Snapshot: Codable, Equatable {
    var rootBookmark: Data? = nil
    /// 最后使用的工作区路径（槽位 key，v2 新增）
    var lastRootPath: String? = nil
    /// 各工作区现场（按根路径分槽，v2 新增）
    var workspaces: [String: WorkspaceSnapshot] = [:]
    /// md 文件路径 -> 上次光标行（1 起；按文件路径 key，天然跨工作区共享）
    var cursorLines: [String: Int] = [:]
    // —— 以下为 v1 遗留字段：仅解码迁移用（归入 lastRoot 槽位），不再写入 ——
    var collapsedFolders: [String] = []
    var groups: [[TabState]] = []
    var activeTabs: [String?] = []
    var activeGroup: Int = 0

    /// 兼容解码：缺失字段回退默认（快照格式向后演进时不炸）
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      rootBookmark = try container.decodeIfPresent(Data.self, forKey: .rootBookmark)
      lastRootPath = try container.decodeIfPresent(String.self, forKey: .lastRootPath)
      workspaces = try container.decodeIfPresent([String: WorkspaceSnapshot].self, forKey: .workspaces) ?? [:]
      cursorLines = try container.decodeIfPresent([String: Int].self, forKey: .cursorLines) ?? [:]
      collapsedFolders = try container.decodeIfPresent([String].self, forKey: .collapsedFolders) ?? []
      groups = try container.decodeIfPresent([[TabState]].self, forKey: .groups) ?? []
      activeTabs = try container.decodeIfPresent([String?].self, forKey: .activeTabs) ?? []
      activeGroup = try container.decodeIfPresent(Int.self, forKey: .activeGroup) ?? 0
    }

    init() {}
  }

  private let defaults: UserDefaults
  private let debouncer = Debouncer(interval: 0.5)
  private static let defaultsKey = "workspaceSnapshot.v1"
  /// 当前状态（各 Store 变化时增量更新，防抖落盘）
  private var state: Snapshot
  /// 当前工作区根路径（tabsDidChange 的槽位 key；nil 表示尚无工作区）
  private(set) var currentRootPath: String?
  /// 切换工作区的目标路径（切换编排期间，watcher 仍以旧 root 触发 workspaceDidChange，
  /// 必须忽略——否则槽位指针被拉回旧工作区，随后的 replaceAll 把空白草稿写进旧槽、清掉真实标签）
  private var pendingSwitchPath: String?
  /// 恢复时取得的安全作用域资源（保持访问至进程结束，否则工作区授权失效）
  private var accessedRootURL: URL?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.defaultsKey),
      let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
    {
      state = decoded
    } else {
      state = Snapshot()
    }
  }

  // MARK: - 状态记录（各 Store 变化时调用）

  /// 标签结构变化（开/关/移动/分栏/激活切换）：写入当前工作区槽位
  func tabsDidChange(groups: [TabGroup], activeGroupID: TabGroup.ID) {
    guard let rootPath = currentRootPath else { return }  // 无工作区不入槽
    var ws = state.workspaces[rootPath] ?? WorkspaceSnapshot()
    ws.groups = groups.map { group in
      group.tabs.map { TabState(path: $0.url?.path, kind: $0.kind.rawValue) }
    }
    ws.activeTabs = groups.map { $0.activeTab?.url?.path }
    ws.activeGroup = groups.firstIndex { $0.id == activeGroupID } ?? 0
    state.workspaces[rootPath] = ws
    schedulePersist()
  }

  /// 槽位 key 统一标准化（/tmp→/private/tmp 等符号链接归一，防止同一文件夹两个 key）
  private func slotKey(for url: URL) -> String {
    url.standardizedFileURL.path
  }

  /// 工作区变化（打开新文件夹 / 折叠态变化）：根目录存 security-scoped bookmark
  func workspaceDidChange(root: URL?, collapsedFolders: Set<URL>) {
    // 切换编排期间：watcher 上报的还是旧 root（异步扫描未完成）或折叠态赋值的路过事件，一律忽略
    if let pending = pendingSwitchPath {
      guard let root, slotKey(for: root) == pending else { return }
      pendingSwitchPath = nil  // 新 root 到达，切换落定，走正常流程
    }
    if let root {
      let key = slotKey(for: root)
      currentRootPath = key
      state.lastRootPath = key
      state.rootBookmark = try? root.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      var ws = state.workspaces[key] ?? WorkspaceSnapshot()
      ws.collapsedFolders = collapsedFolders.map(\.path).sorted()
      state.workspaces[key] = ws
    } else {
      currentRootPath = nil
      state.lastRootPath = nil
      state.rootBookmark = nil
    }
    schedulePersist()
  }

  /// md 光标行记录（内核 500ms 防抖上报）
  func recordCursor(url: URL, line: Int) {
    state.cursorLines[url.path] = line
    schedulePersist()
  }

  /// 某 md 文件的上次光标行（载入恢复用）
  func cursorLine(for url: URL) -> Int? {
    state.cursorLines[url.path]
  }

  // MARK: - 启动恢复

  /// 恢复标签组与激活状态（当前工作区槽位的现场；一般在 restoreWorkspace 之后调用，
  /// 授权失败时回退 lastRootPath，保持与 v1「无工作区也恢复标签」一致的行为）
  func restoreTabs(into tabStore: TabStore) {
    guard let rootPath = currentRootPath ?? state.lastRootPath,
      let ws = state.workspaces[rootPath] else { return }
    tabStore.restore(
      tabStates: ws.groups,
      activeTabPaths: ws.activeTabs,
      activeGroupIndex: ws.activeGroup
    )
  }

  /// 恢复工作区：解析 bookmark → 取得安全作用域访问权 → 打开文件夹 → 恢复折叠态
  func restoreWorkspace(into workspaceStore: WorkspaceStore) {
    guard let bookmark = state.rootBookmark else { return }
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
    currentRootPath = key
    state.lastRootPath = key
    migrateLegacySnapshotIfNeeded(forRoot: key)
    workspaceStore.openFolder(url)
    let ws = state.workspaces[key]
    workspaceStore.collapsedFolders = Set((ws?.collapsedFolders ?? []).map { URL(fileURLWithPath: $0) })
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
    state.lastRootPath = target.path
    pendingSwitchPath = target.path
    workspaceStore.openFolder(target)
    if let ws = state.workspaces[target.path] {
      workspaceStore.collapsedFolders = Set(ws.collapsedFolders.map { URL(fileURLWithPath: $0) })
      tabStore.replaceAll(tabStates: ws.groups, activeTabPaths: ws.activeTabs, activeGroupIndex: ws.activeGroup)
    } else {
      workspaceStore.collapsedFolders = []
      tabStore.replaceAll(tabStates: [], activeTabPaths: [], activeGroupIndex: 0)
    }
  }

  /// v1 快照迁移：旧的全局标签组归入「最后工作区」槽位（迁移后即清空遗留字段，只执行一次）
  private func migrateLegacySnapshotIfNeeded(forRoot rootPath: String) {
    guard state.workspaces[rootPath] == nil, !state.groups.isEmpty else { return }
    state.workspaces[rootPath] = WorkspaceSnapshot(
      collapsedFolders: state.collapsedFolders,
      groups: state.groups,
      activeTabs: state.activeTabs,
      activeGroup: state.activeGroup
    )
    // 迁移完成后清空遗留字段，避免重复迁移
    state.groups = []
    state.activeTabs = []
    state.collapsedFolders = []
    state.activeGroup = 0
  }

  // MARK: - 落盘

  private func schedulePersist() {
    debouncer.schedule { [weak self] in
      self?.persist()
    }
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(state) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }

  /// 立即落盘挂起的快照（退出前调用）
  func flush() {
    debouncer.fire()
  }
}
