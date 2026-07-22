import Foundation

/// 标签组（FR-1.4）：单栏/分栏中一栏的标签集合与激活状态。
/// 每个 Markdown 标签持有独立的 EditorStore（文本/模式/大纲/自动保存互不干扰）。
@MainActor
final class TabGroup: ObservableObject, Identifiable {
  let id = UUID()
  /// 已打开的标签（有序）
  @Published var tabs: [EditorTab] = [] {
    didSet { onStructureChange?() }
  }
  /// 激活标签
  @Published var activeTabID: EditorTab.ID? {
    didSet { onStructureChange?() }
  }
  /// md 标签各自的编辑状态
  @Published private(set) var editorStores: [EditorTab.ID: EditorStore] = [:]
  /// 结构变化回调（FR-1.6 快照；由 TabStore 接线转发）
  var onStructureChange: (() -> Void)?
  /// 光标行上报转发（FR-1.6；由 TabStore 接线）
  var onEditorCursorLine: ((URL, Int) -> Void)?

  var activeTab: EditorTab? {
    tabs.first { $0.id == activeTabID }
  }

  /// 激活的 md 标签的编辑状态（pdf/图片标签为 nil）
  var activeEditorStore: EditorStore? {
    guard let tab = activeTab, tab.kind == .markdown else { return nil }
    return editorStore(for: tab)
  }

  /// body 期兜底已派发、待注册的 store（同一 runloop 内复用同一实例，避免重复创建导致视图与字典分叉）
  private var pendingFallbackStores: [EditorTab.ID: EditorStore] = [:]

  /// 取标签的编辑状态（只读命中：store 一律在 open/restore/attach 等动作阶段预建，见 prepareStore）。
  /// 万一在视图 body 求值期缺失（漏接入的入口），兜底延迟到下一 runloop 注册与载入，
  /// 避免视图更新途中发布 @Published（"Publishing changes from within view updates"）。
  func editorStore(for tab: EditorTab) -> EditorStore {
    if let store = editorStores[tab.id] {
      // 文件被移入废纸篓后标签转草稿；从废纸篓放回原处再点击时重新载入磁盘内容，
      // 恢复落盘能力（否则自动保存永远静默跳过）。文件不在原位（仍在废纸篓）时跳过，避免误报
      if let url = tab.url, store.trashedFileURL == url,
        FileManager.default.fileExists(atPath: url.path)
      {
        store.loadFile(url)
      }
      return store
    }
    // body 期兜底（正常不会走到）：先返回新实例保证本次求值可用，注册推迟到下一 runloop
    if let pending = pendingFallbackStores[tab.id] { return pending }
    let store = EditorStore()
    store.onCursorLineChange = { [weak self] url, line in
      self?.onEditorCursorLine?(url, line)
    }
    pendingFallbackStores[tab.id] = store
    DispatchQueue.main.async { [weak self, weak store] in
      guard let self, let store else { return }
      self.pendingFallbackStores[tab.id] = nil
      // 期间标签可能已关闭、或已被动作阶段预建：以既有者为准
      guard self.editorStores[tab.id] == nil, self.tabs.contains(where: { $0.id == tab.id }) else { return }
      self.editorStores[tab.id] = store
      if let url = tab.url { store.loadFile(url) }
    }
    return store
  }

  /// 动作阶段预建编辑状态（open/restore/attach/fileDidMove 调用）：
  /// 建 store 会发布 editorStores，必须在动作阶段完成，不能落在视图 body 求值期。
  /// 仅 md 标签需要编辑状态（pdf/图片无 EditorStore，与此前惰性创建的口径一致）
  func prepareStore(for tab: EditorTab) {
    guard tab.kind == .markdown, editorStores[tab.id] == nil else { return }
    editorStores[tab.id] = makeStore(for: tab)
  }

  /// 建 store 并接线光标上报；文件标签创建即载入磁盘内容
  private func makeStore(for tab: EditorTab) -> EditorStore {
    let store = EditorStore()
    store.onCursorLineChange = { [weak self] url, line in
      self?.onEditorCursorLine?(url, line)
    }
    if let url = tab.url {
      store.loadFile(url)
    }
    return store
  }

  /// 新建草稿标签（欢迎文档）
  func openDraft() {
    let tab = EditorTab(url: nil, kind: .markdown)
    prepareStore(for: tab)
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
    prepareStore(for: tab)
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
    if let store {
      editorStores[tab.id] = store
    } else {
      prepareStore(for: tab)
    }
    tabs.append(tab)
    activeTabID = tab.id
  }

  /// 全部标签落盘（退出前兜底）
  func flushAll() {
    for store in editorStores.values {
      store.flushPendingSave()
    }
  }

  /// 文件被重命名/移动（FR-1.2 联动）：标签 URL 与编辑状态字典键同步迁移。
  /// 文件夹移动时其后代标签按新前缀一并迁移（按路径组件边界匹配，/a/b 不误伤 /a/b2）；
  /// 扩展名变化按新 URL 重算 kind（md 改名 png 后不再按 Markdown 渲染；png 改名 md 则补建编辑状态）。
  /// 已知限制：文件夹整体移动不重写后代 md 的相对图片链接（rewriteImageLinksAfterMove 仅覆盖单文件
  /// 移动；assets 固定在工作区根，仅跨深度移动文件夹时链接才可能失效，重写代价大，暂不处理）。
  func fileDidMove(from oldURL: URL, to newURL: URL) {
    for index in tabs.indices {
      guard let oldTabURL = tabs[index].url else { continue }
      let newTabURL: URL
      if oldTabURL == oldURL {
        newTabURL = newURL
      } else if oldTabURL.isDescendant(of: oldURL) {
        // 文件夹后代：旧前缀替换为新前缀
        newTabURL = newURL.appendingPathComponent(String(oldTabURL.path.dropFirst(oldURL.path.count + 1)))
      } else {
        continue
      }
      let oldTabID = tabs[index].id
      if let store = editorStores[oldTabID] {
        editorStores[newTabURL.path] = store
        editorStores[oldTabID] = nil
        store.fileDidMove(from: oldTabURL, to: newTabURL)
      }
      // kind 按新 URL 重算（扩展名可能被改掉）
      let newKind = FileNode.kind(for: newTabURL, isDirectory: false)
      tabs[index] = EditorTab(url: newTabURL, kind: newKind)
      // 重命名为 md（如 png → md）：动作阶段补建编辑状态（body 期不建 store）
      if newKind == .markdown, editorStores[newTabURL.path] == nil {
        editorStores[newTabURL.path] = makeStore(for: tabs[index])
      }
      // 激活标签的 id 也随路径迁移（否则 activeTab 解析不到，内容区变空白）
      if activeTabID == oldTabID {
        activeTabID = newTabURL.path
      }
    }
  }

  /// 文件/文件夹被移入废纸篓（FR-1.2 联动）：命中标签（含文件夹后代）的编辑状态转草稿
  func fileWasTrashed(_ url: URL) {
    for tab in tabs {
      guard let tabURL = tab.url, tabURL == url || tabURL.isDescendant(of: url) else { continue }
      editorStores[tab.id]?.fileWasTrashed(tabURL)
    }
  }
}

private extension URL {
  /// 是否位于某文件夹 URL 之内（按路径组件边界比较：/a/b 的后代不含 /a/b2）
  func isDescendant(of folder: URL) -> Bool {
    path.hasPrefix(folder.path + "/")
  }
}
