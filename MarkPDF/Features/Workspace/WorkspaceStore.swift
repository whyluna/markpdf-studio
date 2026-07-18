import AppKit
import Foundation
import os

/// 工作区状态（FR-1.1）：根文件夹、文件树扫描、当前选中节点。
/// 沙盒授权来自 NSOpenPanel 的用户选择（entitlements: files.user-selected.read-write）。
/// 与 EditorStore 一致：主线程使用（开发规范 §3.2）。
final class WorkspaceStore: ObservableObject {
  /// 已打开的工作区根节点（nil = 尚未打开）
  @Published private(set) var root: FileNode?
  /// 文件树当前选中节点（ContentView 据此分发中间栏内容）
  @Published var selection: FileNode?
  /// 正在扫描（大文件夹时供 UI 显示进度）
  @Published private(set) var isLoading = false
  /// 最近一次文件操作错误（视图据此弹 alert）
  @Published var lastError: String?
  /// 快速打开面板（FR-6.1 ⌘P）是否展示
  @Published var isQuickOpenPresented = false
  /// 折叠的文件夹（FR-1.1 树展开态；默认全部展开，点击文件夹行切换，重扫后按 URL 保留）
  @Published var collapsedFolders: Set<URL> = []

  /// 点击文件夹行：切换展开/收起
  func toggleFolderCollapsed(_ url: URL) {
    if collapsedFolders.contains(url) {
      collapsedFolders.remove(url)
    } else {
      collapsedFolders.insert(url)
    }
  }

  /// 文件操作服务（FR-1.2；可注入 mock 测试）
  private let ops: FileOperations
  /// 目录监听服务（FR-1.3）：外部变更时自动重扫
  private let watcher: FileWatcher
  /// 递归深度上限，防御符号链接环 / 异常目录
  private static let maxDepth = 12
  private var scanTask: Task<Void, Never>?

  init(ops: FileOperations = LiveFileOperations(), watcher: FileWatcher = LiveFileWatcher()) {
    self.ops = ops
    self.watcher = watcher
  }

  /// 弹出系统面板选择工作区文件夹
  func openFolderPanel() {
    let panel = NSOpenPanel()
    panel.title = "选择工作区文件夹"
    panel.message = "选择包含 Markdown / PDF 的文件夹，作为工作区打开"
    panel.prompt = "打开"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openFolder(url)
  }

  /// 打开文件夹并后台扫描（避免大目录卡住 UI）；同时启动外部变更监听（FR-1.3）
  func openFolder(_ url: URL) {
    scanTask?.cancel()
    selection = nil
    isLoading = true
    Logger.workspace.info("打开工作区: \(url.path, privacy: .public)")
    scan(url, showLoading: true)
    watcher.startWatching(url: url) { [weak self] in
      self?.refresh()
    }
  }

  /// 重扫当前工作区（文件操作 / 外部变更后调用）；默认保留选中，可指定改选新 URL。
  /// 静默执行（不闪 loading），扫描完成即更新。
  func refresh(selecting selectURL: URL? = nil) {
    guard let root else { return }
    let keepURL = selectURL ?? selection?.id
    scanTask?.cancel()
    scan(root.id) { [weak self] in
      guard let keepURL, let tree = self?.root else { return }
      self?.selection = tree.find(keepURL)
    }
  }

  /// 按 URL 查找当前树中的节点（拖拽落点解析）
  func node(for url: URL) -> FileNode? {
    root?.find(url)
  }

  /// 扁平化文件列表（FR-6.1 快速打开候选；仅文件，深度优先）
  var allFiles: [FileNode] {
    guard let root else { return [] }
    var result: [FileNode] = []
    func walk(_ node: FileNode) {
      if node.isFolder {
        node.children?.forEach(walk)
      } else {
        result.append(node)
      }
    }
    walk(root)
    return result
  }

  // MARK: - 文件操作（FR-1.2）

  /// 新建 Markdown 文件（唯一默认名，随后由视图进入行内命名）；返回新文件 URL
  @discardableResult
  func createMarkdown(in folder: URL, undo: UndoManager?) -> URL? {
    let url = ops.uniqueFileURL(in: folder, baseName: "未命名", ext: "md")
    do {
      try ops.createFile(at: url)
      refresh(selecting: url)
      registerCreateUndo(url, undo: undo)
      return url
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  /// 新建文件夹（唯一默认名）；返回新文件夹 URL
  @discardableResult
  func createFolder(in folder: URL, undo: UndoManager?) -> URL? {
    let url = ops.uniqueFolderURL(in: folder, baseName: "未命名文件夹")
    do {
      try ops.createFolder(at: url)
      refresh(selecting: url)
      registerCreateUndo(url, undo: undo)
      return url
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  /// 重命名；返回新 URL（失败为 nil）。撤销/重做随调用链自动注册
  @discardableResult
  func rename(_ node: FileNode, to newName: String, undo: UndoManager?) -> URL? {
    do {
      let newURL = try ops.rename(at: node.id, to: newName)
      if newURL != node.id {
        refresh(selecting: newURL)
        undo?.registerUndo(withTarget: self) { target in
          target.rename(FileNode(id: newURL, name: newURL.lastPathComponent, kind: node.kind), to: node.name, undo: undo)
        }
        undo?.setActionName("重命名")
      }
      return newURL
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  /// 移动到目标文件夹；返回新 URL（失败为 nil）
  @discardableResult
  func move(_ node: FileNode, toFolder folder: URL, undo: UndoManager?) -> URL? {
    // 防御：文件夹不能移入自身或其后代
    if node.isFolder {
      let nodePath = node.id.path
      if folder.path == nodePath || folder.path.hasPrefix(nodePath + "/") {
        lastError = "不能移动到自身或其子文件夹内"
        return nil
      }
    }
    do {
      let newURL = try ops.move(at: node.id, toFolder: folder)
      if newURL != node.id {
        refresh(selecting: newURL)
        undo?.registerUndo(withTarget: self) { target in
          target.move(
            FileNode(id: newURL, name: node.name, kind: node.kind),
            toFolder: node.id.deletingLastPathComponent(),
            undo: undo
          )
        }
        undo?.setActionName("移动")
      }
      return newURL
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  /// 移入系统废纸篓（可从废纸篓恢复；不注册 Cmd+Z，对齐 PRD 验收口径）
  func trash(_ node: FileNode) {
    do {
      try ops.trash(at: node.id)
      if selection == node { selection = nil }
      refresh()
    } catch {
      lastError = error.localizedDescription
    }
  }

  // MARK: - 撤销辅助

  private func registerCreateUndo(_ url: URL, undo: UndoManager?) {
    undo?.registerUndo(withTarget: self) { target in
      target.trashCreated(url, undo: undo)
    }
    undo?.setActionName("新建")
  }

  /// 「新建」的撤销 = 入废纸篓；并注册重做
  private func trashCreated(_ url: URL, undo: UndoManager?) {
    try? ops.trash(at: url)
    refresh()
    undo?.registerUndo(withTarget: self) { target in
      target.recreate(url, undo: undo)
    }
  }

  private func recreate(_ url: URL, undo: UndoManager?) {
    try? ops.createFile(at: url)
    refresh(selecting: url)
    undo?.registerUndo(withTarget: self) { target in
      target.trashCreated(url, undo: undo)
    }
  }

  private func scan(_ url: URL, showLoading: Bool = false, completion: (() -> Void)? = nil) {
    if showLoading { isLoading = true }
    scanTask = Task.detached(priority: .userInitiated) { [weak self] in
      let tree = Self.scan(url: url, depth: 0)
      // 转强引用（let）：消除“并发代码捕获 var self”的 Swift 6 预警
      guard !Task.isCancelled, let self else { return }
      await MainActor.run {
        self.root = tree
        self.isLoading = false
        completion?()
      }
    }
  }

  /// 递归扫描：跳过隐藏文件；过滤不受支持的文件；目录一律保留。
  /// 排序规则：文件夹在前，同类按本地化文件名排序（访达一致）。
  private static func scan(url: URL, depth: Int) -> FileNode {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    let kind = FileNode.kind(for: url, isDirectory: isDirectory.boolValue)

    var children: [FileNode]?
    if isDirectory.boolValue {
      if depth < maxDepth {
        let urls = (try? fileManager.contentsOfDirectory(
          at: url,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )) ?? []
        children = urls
          .map { scan(url: $0, depth: depth + 1) }
          .filter { node in
            // 仅过滤不受支持的文件；目录一律保留（空目录也可见，
            // 否则新建的文件夹会从树中"消失"，表现为新建没反应）
            node.kind != .other
          }
          .sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
          }
      } else {
        children = []
      }
    }
    return FileNode(id: url, name: url.lastPathComponent, kind: kind, children: children)
  }
}
