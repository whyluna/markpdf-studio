import Foundation

/// 工作区快照的单一所有者（v1.5 多窗口）：Snapshot + UserDefaults + 防抖落盘。
/// App 级单实例，各窗口的 WorkspaceStateStore（facade）共享读写——
/// 若每窗口各持一份完整 Snapshot 副本，互相整体覆盖会丢别的窗口的槽位。
@MainActor
final class WorkspaceSnapshotStore: ObservableObject {
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
    /// AI 助手面板显隐（FR-AI.2；Optional 保旧快照可解码，nil = 关）
    var aiAssistantVisible: Bool? = nil
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
  /// 当前状态（facade 增量更新后调 schedulePersist）
  var state: Snapshot

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

  func schedulePersist() {
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
