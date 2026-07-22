import Foundation

/// 标签页总控（FR-1.4）：1~2 个标签组（单栏/左右分栏）、激活组、跨组移动。
@MainActor
final class TabStore: ObservableObject {
  @Published private(set) var groups: [TabGroup] {
    didSet { onStructureChange?() }
  }
  @Published var activeGroupID: TabGroup.ID {
    didSet { onStructureChange?() }
  }
  /// 拖拽中的标签（应用内拖拽共享状态）
  var draggingTab: (tab: EditorTab, from: TabGroup.ID)?
  /// 文件被打开的回调（FR-1.5 最近打开记录；由 App 层接线，与工作区根路径关联）
  var onOpenFile: ((URL) -> Void)?
  /// 标签结构变化回调（FR-1.6 快照保存；由 App 层接线）
  var onStructureChange: (() -> Void)?
  /// 光标行上报（FR-1.6；经 TabGroup 转发到 App 层）
  var onEditorCursorLine: ((URL, Int) -> Void)?

  init() {
    let group = TabGroup()
    groups = [group]
    activeGroupID = group.id
    wireGroup(group)
    group.openDraft()
  }

  /// 组回调接线：结构变化与光标上报转发到 Store 级闭包
  private func wireGroup(_ group: TabGroup) {
    group.onStructureChange = { [weak self] in
      self?.onStructureChange?()
    }
    group.onEditorCursorLine = { [weak self] url, line in
      self?.onEditorCursorLine?(url, line)
    }
  }

  /// 新建已接线的组
  private func makeGroup() -> TabGroup {
    let group = TabGroup()
    wireGroup(group)
    return group
  }

  var isSplit: Bool { groups.count > 1 }

  var activeGroup: TabGroup {
    groups.first { $0.id == activeGroupID } ?? groups[0]
  }

  /// 激活组的激活 md 标签编辑状态（工具栏/大纲/状态栏的数据源）
  var activeEditorStore: EditorStore? {
    activeGroup.activeEditorStore
  }

  /// 在当前组打开文件
  func open(_ node: FileNode) {
    activeGroup.open(node)
    onOpenFile?(node.id)
  }

  /// 按 URL 打开文件（导出笔记后打开、最近打开等场景）
  func open(url: URL) {
    open(FileNode(id: url, name: url.lastPathComponent, kind: FileNode.kind(for: url, isDirectory: false)))
  }

  /// 切换分栏：无则创建空右组；有则右组标签并回左组
  func toggleSplit() {
    if isSplit, let right = groups.last {
      for tab in right.tabs {
        let store = right.detach(tab)
        groups[0].attach(tab, store: store)
      }
      groups = [groups[0]]
      activeGroupID = groups[0].id
    } else {
      let right = makeGroup()
      groups.append(right)
    }
  }

  /// 把标签移到另一组（目标组不存在则先创建）
  func moveTab(_ tab: EditorTab, from source: TabGroup, to target: TabGroup?) {
    let targetGroup = target ?? {
      let group = makeGroup()
      groups.append(group)
      return group
    }()
    guard source.id != targetGroup.id else { return }
    let store = source.detach(tab)
    targetGroup.attach(tab, store: store)
    activeGroupID = targetGroup.id
    collapseIfEmpty(source)
  }

  /// 空组自动收起（回到单栏）
  private func collapseIfEmpty(_ group: TabGroup) {
    guard groups.count > 1, group.tabs.isEmpty else { return }
    groups.removeAll { $0.id == group.id }
    activeGroupID = groups[0].id
  }

  /// 打开中的文件被重命名/移动：转发各组处理（FR-1.2 联动）
  func fileDidMove(from oldURL: URL, to newURL: URL) {
    for group in groups {
      group.fileDidMove(from: oldURL, to: newURL)
    }
  }

  /// 打开中的文件被移入废纸篓：对应标签的编辑状态转草稿（FR-1.2 联动）
  func fileWasTrashed(_ url: URL) {
    for group in groups {
      group.fileWasTrashed(url)
    }
  }

  /// 全部标签落盘（退出前兜底）
  func flushAll() {
    for group in groups {
      group.flushAll()
    }
  }

  // MARK: - 状态恢复（FR-1.6）

  /// restore 只执行一次：onAppear 每次进窗都触发，重复 restore 会用快照整体替换 groups、
  /// 丢弃内存中 TabGroup 持有的 EditorStore（含草稿正文，快照只有 path 不含正文）
  private var didRestore = false

  /// 从快照重建标签组与激活状态（启动恢复现场）。
  /// 空快照保留启动默认的草稿标签；直接操作 TabGroup，不触发打开记录/快照回写之外的副作用。
  func restore(tabStates: [[WorkspaceStateStore.TabState]], activeTabPaths: [String?], activeGroupIndex: Int) {
    guard !didRestore else { return }
    didRestore = true
    let restored: [TabGroup] = tabStates.map { states in
      let group = makeGroup()
      for state in states {
        let url = state.path.map { URL(fileURLWithPath: $0) }
        let kind = FileNode.Kind(rawValue: state.kind) ?? .markdown
        group.tabs.append(EditorTab(url: url, kind: kind))
      }
      return group
    }
    // 空组（如退出时残留的空白分栏）不恢复；全空则保留默认草稿
    let nonEmpty = restored.filter { !$0.tabs.isEmpty }
    guard !nonEmpty.isEmpty else { return }
    groups = nonEmpty
    for (index, group) in groups.enumerated() {
      // 文件标签 id 即路径；草稿不可指认（id 为 UUID），回退到组尾标签
      let activePath = index < activeTabPaths.count ? activeTabPaths[index] : nil
      group.activeTabID = activePath ?? group.tabs.last?.id
    }
    let safeIndex = min(max(activeGroupIndex, 0), groups.count - 1)
    activeGroupID = groups[safeIndex].id
  }
}
