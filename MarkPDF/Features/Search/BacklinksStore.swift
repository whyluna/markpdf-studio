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
    self.target = target
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
      let found = BacklinksFinder.find(target: target, in: files, workspaceRoot: workspaceRoot)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.items = found
        self?.isScanning = false
      }
    }
  }
}
