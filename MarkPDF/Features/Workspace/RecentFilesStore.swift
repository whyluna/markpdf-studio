import Foundation

/// 最近打开（FR-1.5）：按工作区根路径持久化最近打开文件（新→旧），重启保留。
/// 上限 10 条（用户决策，PRD 原 20 条）。
/// 已删除文件的清理在写入路径（record）顺带完成——读取为纯读，不得在视图 body 求值期
/// 发布 @Published（"Publishing changes from within view updates"）；
/// 展示层的存在性过滤由 FileTreeView.collectionSection 负责。
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

  /// 某工作区的最近打开（新到旧；纯读——已删除文件的清理由 record 顺带完成）
  func files(forRoot root: URL) -> [URL] {
    (recents[root.path] ?? []).map { URL(fileURLWithPath: $0) }
  }

  /// 记录一次打开：去重置顶、顺带清理已删除的文件、超出上限截断后写盘
  func record(_ url: URL, forRoot root: URL) {
    var paths = recents[root.path] ?? []
    paths.removeAll { $0 == url.path }
    paths.insert(url.path, at: 0)
    // 清理已删除的文件（原在读路径做，会在 body 求值期发布 @Published）
    paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
    if paths.count > Self.limit {
      paths = Array(paths.prefix(Self.limit))
    }
    recents[root.path] = paths
    defaults.set(recents, forKey: Self.defaultsKey)
  }
}
