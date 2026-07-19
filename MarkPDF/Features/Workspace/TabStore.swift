import Foundation

/// 标签页总控（FR-1.4）：1~2 个标签组（单栏/左右分栏）、激活组、跨组移动。
@MainActor
final class TabStore: ObservableObject {
  @Published private(set) var groups: [TabGroup]
  @Published var activeGroupID: TabGroup.ID
  /// 拖拽中的标签（应用内拖拽共享状态）
  var draggingTab: (tab: EditorTab, from: TabGroup.ID)?

  init() {
    let group = TabGroup()
    groups = [group]
    activeGroupID = group.id
    group.openDraft()
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
      let right = TabGroup()
      groups.append(right)
    }
  }

  /// 把标签移到另一组（目标组不存在则先创建）
  func moveTab(_ tab: EditorTab, from source: TabGroup, to target: TabGroup?) {
    let targetGroup = target ?? {
      let group = TabGroup()
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
}
