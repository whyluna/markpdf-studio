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

  /// 某工作区的最近打开（新到旧；纯读——已删除文件的清理由 record 顺带完成）。
/// 越界条目（历史版本误录、md 链接点开工作区外文件）在读出时按工作区归属滤掉——
/// 「最近打开」是「这个工作区的最近打开」，侧栏不应出现别的工作区的文件
  func files(forRoot root: URL) -> [URL] {
    let rootPath = root.standardizedFileURL.path
    return (recents[root.path] ?? [])
      .map { URL(fileURLWithPath: $0) }
      .filter { $0.isWithinWorkspace(rootPath: rootPath) }
  }

  /// 记录一次打开：去重置顶、顺带清理已删除的文件、超出上限截断后写盘。
  /// 工作区外的文件不记录（点击 md 链接、外部打开路由都可能把异根路径送到这里——
  /// 越界文件点了也因沙盒无权限打不开，还会污染侧栏）
  func record(_ url: URL, forRoot root: URL) {
    let rootPath = root.standardizedFileURL.path
    guard url.isWithinWorkspace(rootPath: rootPath) else { return }
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

  /// 文件/文件夹改名或移动（应用内）：条目随路径平移（文件夹后代按前缀），
  /// 平移后去重（新路径恰好已在列表时不产生两条）。幂等：旧路径不存在为 no-op
  func rekey(from oldPath: String, to newPath: String) {
    guard oldPath != newPath else { return }
    var changed = false
    for (root, paths) in recents {
      let shifted = Self.dedupe(paths.map { Self.shift($0, from: oldPath, to: newPath) })
      if shifted != paths {
        recents[root] = shifted
        changed = true
      }
    }
    if changed {
      defaults.set(recents, forKey: Self.defaultsKey)
    }
  }

  /// 路径前缀平移（与 AISessionRepository.rekey 同口径；三处共用，改动须同步）
  nonisolated static func shift(_ path: String, from oldPath: String, to newPath: String) -> String {
    guard path == oldPath || path.hasPrefix(oldPath + "/") else { return path }
    return newPath + path.dropFirst(oldPath.count)
  }

  nonisolated static func dedupe(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }
}
