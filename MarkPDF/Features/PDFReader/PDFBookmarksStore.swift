import Foundation

/// PDF 用户书签（FR-3.3）：按文件路径持久化页码集合（UserDefaults）。
@MainActor
final class PDFBookmarksStore: ObservableObject {
  /// filePath -> 已排序页码（1 起）
  @Published private var bookmarks: [String: [Int]] = [:]

  private static let defaultsKey = "pdfBookmarks"

  init() {
    if let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [Int]] {
      bookmarks = saved
    }
  }

  /// 某文件的书签页码（升序）
  func pages(for url: URL) -> [Int] {
    bookmarks[url.path] ?? []
  }

  func contains(page: Int, for url: URL) -> Bool {
    (bookmarks[url.path] ?? []).contains(page)
  }

  /// 添加/移除切换
  func toggle(page: Int, for url: URL) {
    var pages = bookmarks[url.path] ?? []
    if let index = pages.firstIndex(of: page) {
      pages.remove(at: index)
    } else {
      pages.append(page)
      pages.sort()
    }
    bookmarks[url.path] = pages
    persist()
  }

  func remove(page: Int, for url: URL) {
    var pages = bookmarks[url.path] ?? []
    pages.removeAll { $0 == page }
    bookmarks[url.path] = pages
    persist()
  }

  private func persist() {
    UserDefaults.standard.set(bookmarks, forKey: Self.defaultsKey)
  }
}
