import Foundation

/// 最近打开（FR-1.5）：按工作区根路径持久化最近打开文件（新→旧），重启保留。
/// 上限 10 条（用户决策，PRD 原 20 条）；读取时自动清理已删除的文件并回写。
@MainActor
final class RecentFilesStore: ObservableObject {
  /// rootPath -> 文件路径（新到旧）
  @Published private var recents: [String: [String]] = [:]

  private let defaults: UserDefaults
  private static let defaultsKey = "recentFiles"
  /// 上限（用户决策 10 条；PRD FR-1.5 原为 20 条）
  static let limit = 10

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] {
      recents = saved
    }
  }

  /// 某工作区的最近打开（新到旧；已删除的文件自动清理并回写存储）
  func files(forRoot root: URL) -> [URL] {
    let paths = recents[root.path] ?? []
    let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
    if existing.count != paths.count {
      recents[root.path] = existing
      defaults.set(recents, forKey: Self.defaultsKey)
    }
    return existing.map { URL(fileURLWithPath: $0) }
  }

  /// 记录一次打开：去重置顶，超出上限截断
  func record(_ url: URL, forRoot root: URL) {
    var paths = recents[root.path] ?? []
    paths.removeAll { $0 == url.path }
    paths.insert(url.path, at: 0)
    if paths.count > Self.limit {
      paths = Array(paths.prefix(Self.limit))
    }
    recents[root.path] = paths
    defaults.set(recents, forKey: Self.defaultsKey)
  }
}
