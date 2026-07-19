import Foundation
import os

/// 工作区状态持久化（FR-1.6）：快照存 UserDefaults（JSON），0.5s 防抖落盘，启动恢复现场。
/// 快照内容：工作区根（security-scoped bookmark）、折叠文件夹、标签组/激活状态、md 光标行。
/// PDF 阅读位置由 PDFReadingPositionStore 单独持久化（FR-3.5），不在此快照内。
@MainActor
final class WorkspaceStateStore: ObservableObject {
  /// 单个标签的快照（path 为 nil 表示未命名草稿）
  struct TabState: Codable, Equatable {
    var path: String?
    var kind: String
  }

  struct Snapshot: Codable, Equatable {
    var rootBookmark: Data? = nil
    var collapsedFolders: [String] = []
    var groups: [[TabState]] = []
    /// 各组激活标签路径（草稿激活为 nil）
    var activeTabs: [String?] = []
    var activeGroup: Int = 0
    /// md 文件路径 -> 上次光标行（1 起）
    var cursorLines: [String: Int] = [:]

    /// 兼容解码：缺失字段回退默认（快照格式向后演进时不炸）
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      rootBookmark = try container.decodeIfPresent(Data.self, forKey: .rootBookmark)
      collapsedFolders = try container.decodeIfPresent([String].self, forKey: .collapsedFolders) ?? []
      groups = try container.decodeIfPresent([[TabState]].self, forKey: .groups) ?? []
      activeTabs = try container.decodeIfPresent([String?].self, forKey: .activeTabs) ?? []
      activeGroup = try container.decodeIfPresent(Int.self, forKey: .activeGroup) ?? 0
      cursorLines = try container.decodeIfPresent([String: Int].self, forKey: .cursorLines) ?? [:]
    }

    init() {}
  }

  private let defaults: UserDefaults
  private let debouncer = Debouncer(interval: 0.5)
  private static let defaultsKey = "workspaceSnapshot.v1"
  /// 当前状态（各 Store 变化时增量更新，防抖落盘）
  private var state: Snapshot
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

  /// 标签结构变化（开/关/移动/分栏/激活切换）
  func tabsDidChange(groups: [TabGroup], activeGroupID: TabGroup.ID) {
    state.groups = groups.map { group in
      group.tabs.map { TabState(path: $0.url?.path, kind: $0.kind.rawValue) }
    }
    state.activeTabs = groups.map { $0.activeTab?.url?.path }
    state.activeGroup = groups.firstIndex { $0.id == activeGroupID } ?? 0
    schedulePersist()
  }

  /// 工作区变化（打开新文件夹 / 折叠态变化）：根目录存 security-scoped bookmark
  func workspaceDidChange(root: URL?, collapsedFolders: Set<URL>) {
    state.collapsedFolders = collapsedFolders.map(\.path).sorted()
    if let root {
      state.rootBookmark = try? root.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } else {
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

  /// 恢复标签组与激活状态
  func restoreTabs(into tabStore: TabStore) {
    tabStore.restore(
      tabStates: state.groups,
      activeTabPaths: state.activeTabs,
      activeGroupIndex: state.activeGroup
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
    workspaceStore.openFolder(url)
    workspaceStore.collapsedFolders = Set(state.collapsedFolders.map { URL(fileURLWithPath: $0) })
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
