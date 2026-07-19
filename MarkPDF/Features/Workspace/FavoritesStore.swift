import Foundation

/// 收藏夹（FR-1.5）：按工作区根路径持久化收藏文件列表（UserDefaults），重启保留。
@MainActor
final class FavoritesStore: ObservableObject {
  /// rootPath -> 收藏文件路径（有序，新收藏追加在末尾）
  @Published private var favorites: [String: [String]] = [:]

  private let defaults: UserDefaults
  private static let defaultsKey = "favoriteFiles"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] {
      favorites = saved
    }
  }

  /// 某工作区的收藏文件（保持添加顺序）
  func files(forRoot root: URL) -> [URL] {
    (favorites[root.path] ?? []).map { URL(fileURLWithPath: $0) }
  }

  func contains(_ url: URL, forRoot root: URL) -> Bool {
    (favorites[root.path] ?? []).contains(url.path)
  }

  /// 添加/移除切换
  func toggle(_ url: URL, forRoot root: URL) {
    var paths = favorites[root.path] ?? []
    if let index = paths.firstIndex(of: url.path) {
      paths.remove(at: index)
    } else {
      paths.append(url.path)
    }
    favorites[root.path] = paths
    persist()
  }

  func remove(_ url: URL, forRoot root: URL) {
    var paths = favorites[root.path] ?? []
    paths.removeAll { $0 == url.path }
    favorites[root.path] = paths
    persist()
  }

  private func persist() {
    defaults.set(favorites, forKey: Self.defaultsKey)
  }
}
