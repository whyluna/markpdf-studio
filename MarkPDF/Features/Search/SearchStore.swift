import Foundation

/// 全文搜索状态（FR-6.2）：查询防抖、后台执行、结果与取消。
@MainActor
final class SearchStore: ObservableObject {
  @Published var query = "" {
    didSet { scheduleSearch() }
  }
  @Published private(set) var results: [FullTextSearchResult] = []
  @Published private(set) var isSearching = false

  /// 候选文件提供方（App 层接线到工作区文件列表）
  var filesProvider: () -> [URL] = { [] }

  private let debouncer = Debouncer(interval: 0.3)
  private var searchTask: Task<Void, Never>?

  /// 打开面板时重置（保留上次结果之外的状态）
  func reset() {
    searchTask?.cancel()
    query = ""
    results = []
    isSearching = false
  }

  private func scheduleSearch() {
    debouncer.schedule { [weak self] in
      self?.run()
    }
  }

  private func run() {
    searchTask?.cancel()
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard needle.count >= 2 else {
      results = []
      isSearching = false
      return
    }
    isSearching = true
    let files = filesProvider()
    searchTask = Task.detached(priority: .userInitiated) { [weak self] in
      let results = FullTextSearch.search(query: needle, files: files) { Task.isCancelled }
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.results = results
        self?.isSearching = false
      }
    }
  }
}
