import Foundation

/// 标签组（FR-1.4）：单栏/分栏中一栏的标签集合与激活状态。
/// 每个 Markdown 标签持有独立的 EditorStore（文本/模式/大纲/自动保存互不干扰）。
@MainActor
final class TabGroup: ObservableObject, Identifiable {
  let id = UUID()
  /// 已打开的标签（有序）
  @Published var tabs: [EditorTab] = []
  /// 激活标签
  @Published var activeTabID: EditorTab.ID?
  /// md 标签各自的编辑状态
  @Published private(set) var editorStores: [EditorTab.ID: EditorStore] = [:]

  var activeTab: EditorTab? {
    tabs.first { $0.id == activeTabID }
  }

  /// 激活的 md 标签的编辑状态（pdf/图片标签为 nil）
  var activeEditorStore: EditorStore? {
    guard let tab = activeTab, tab.kind == .markdown else { return nil }
    return editorStore(for: tab)
  }

  /// 取标签的编辑状态（惰性创建；文件标签创建即载入磁盘内容）
  func editorStore(for tab: EditorTab) -> EditorStore {
    if let store = editorStores[tab.id] { return store }
    let store = EditorStore()
    editorStores[tab.id] = store
    if let url = tab.url {
      store.loadFile(url)
    }
    return store
  }

  /// 新建草稿标签（欢迎文档）
  func openDraft() {
    let tab = EditorTab(url: nil, kind: .markdown)
    tabs.append(tab)
    activeTabID = tab.id
  }

  /// 打开文件：已开则激活，否则新建标签
  func open(_ node: FileNode) {
    if let existing = tabs.first(where: { $0.url == node.id }) {
      activeTabID = existing.id
      return
    }
    let tab = EditorTab(url: node.id, kind: node.kind)
    tabs.append(tab)
    activeTabID = tab.id
  }

  func activate(_ tab: EditorTab) {
    activeTabID = tab.id
  }

  /// 关闭标签：先把未落盘改动写盘（FR-2.7 兜底）
  func close(_ tab: EditorTab) {
    editorStores[tab.id]?.flushPendingSave()
    editorStores[tab.id] = nil
    tabs.removeAll { $0.id == tab.id }
    if activeTabID == tab.id {
      activeTabID = tabs.last?.id
    }
  }

  /// 组内重排：把标签移到目标标签之前（target 为 nil 移到末尾）
  func moveTab(_ tab: EditorTab, before target: EditorTab?) {
    guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
    let moving = tabs.remove(at: from)
    if let target, let to = tabs.firstIndex(where: { $0.id == target.id }) {
      tabs.insert(moving, at: to)
    } else {
      tabs.append(moving)
    }
  }

  /// 取出标签及其编辑状态（跨组移动用）
  func detach(_ tab: EditorTab) -> EditorStore? {
    tabs.removeAll { $0.id == tab.id }
    if activeTabID == tab.id {
      activeTabID = tabs.last?.id
    }
    return editorStores.removeValue(forKey: tab.id)
  }

  /// 接收跨组移入的标签（可带既有编辑状态）
  func attach(_ tab: EditorTab, store: EditorStore?) {
    tabs.append(tab)
    if let store {
      editorStores[tab.id] = store
    }
    activeTabID = tab.id
  }

  /// 全部标签落盘（退出前兜底）
  func flushAll() {
    for store in editorStores.values {
      store.flushPendingSave()
    }
  }

  /// 文件被重命名/移动（FR-1.2 联动）：标签 URL 与编辑状态字典键同步迁移
  func fileDidMove(from oldURL: URL, to newURL: URL) {
    if let store = editorStores[oldURL.path] {
      editorStores[newURL.path] = store
      editorStores[oldURL.path] = nil
      store.fileDidMove(from: oldURL, to: newURL)
    }
    for index in tabs.indices where tabs[index].url == oldURL {
      tabs[index] = EditorTab(url: newURL, kind: tabs[index].kind)
    }
    // 激活标签的 id 也随路径迁移（否则 activeTab 解析不到，内容区变空白）
    if activeTabID == oldURL.path {
      activeTabID = newURL.path
    }
  }

  /// 文件被移入废纸篓（FR-1.2 联动）：对应编辑状态转草稿
  func fileWasTrashed(_ url: URL) {
    for store in editorStores.values {
      store.fileWasTrashed(url)
    }
  }
}
