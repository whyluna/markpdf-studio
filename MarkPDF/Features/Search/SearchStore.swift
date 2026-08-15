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
        // 取消窗口期防护：任务取消前已通过检查并入了主线程队列的旧块不得落地——
        // 比对发起时的查询快照，过期结果与 isSearching 翻转都丢弃
        guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == needle else { return }
        self.results = results
        self.isSearching = false
      }
    }
  }
}
