import Foundation

/// 最近打开（FR-1.5）：按工作区根路径持久化最近打开文件（新→旧，上限 20 条），重启保留。
@MainActor
final class RecentFilesStore: ObservableObject {
  /// rootPath -> 文件路径（新到旧）
  @Published private var recents: [String: [String]] = [:]

  private let defaults: UserDefaults
  private static let defaultsKey = "recentFiles"
  /// 上限（FR-1.5：最多 20 条）
  static let limit = 20

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] {
      recents = saved
    }
  }

  /// 某工作区的最近打开（新到旧）
  func files(forRoot root: URL) -> [URL] {
    (recents[root.path] ?? []).map { URL(fileURLWithPath: $0) }
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
