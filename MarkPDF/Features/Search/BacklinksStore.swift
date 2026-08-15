import Foundation

/// 反向链接状态（FR-5.4）：跟踪当前文件，防抖后台扫描工作区 md 引用。
@MainActor
final class BacklinksStore: ObservableObject {
  @Published private(set) var items: [Backlink] = []
  @Published private(set) var isScanning = false

  /// 候选 md 文件提供方（App 层接线到工作区文件列表）
  var filesProvider: () -> [URL] = { [] }

  private let debouncer = Debouncer(interval: 0.5)
  private var scanTask: Task<Void, Never>?
  private var target: URL?
  private var workspaceRoot: URL?

  func setWorkspaceRoot(_ url: URL?) {
    workspaceRoot = url
  }

  /// 跟踪目标变化（切换标签/文件）
  func track(_ target: URL?) {
    guard target != self.target else { return }
    self.target = target
    // 换目标即清旧结果：新扫描落地前面板若仍显示上一目标的反链，
    // 分栏对照时会把 A 的引用短暂挂在 B 名下
    items = []
    scheduleScan()
  }

  /// 工作区内容变化（FSEvents 刷新后调用）：当前目标重扫（新引用 5s 内出现）
  func refresh() {
    scheduleScan()
  }

  private func scheduleScan() {
    debouncer.schedule { [weak self] in
      self?.scan()
    }
  }

  private func scan() {
    scanTask?.cancel()
    guard let target, let workspaceRoot else {
      items = []
      isScanning = false
      return
    }
    let files = filesProvider()
    isScanning = true
    scanTask = Task.detached(priority: .utility) { [weak self] in
      let found = BacklinksFinder.find(target: target, in: files, workspaceRoot: workspaceRoot) {
        Task.isCancelled
      }
      guard !Task.isCancelled else { return }
      await MainActor.run {
        // 取消窗口期防护：已过取消检查并入主线程队列的旧块不得覆盖新目标的结果
        guard let self, self.target == target else { return }
        self.items = found
        self.isScanning = false
      }
    }
  }
}
