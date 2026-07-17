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

  /// 递归深度上限，防御符号链接环 / 异常目录
  private static let maxDepth = 12
  private var scanTask: Task<Void, Never>?

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

  /// 打开文件夹并后台扫描（避免大目录卡住 UI）
  func openFolder(_ url: URL) {
    scanTask?.cancel()
    selection = nil
    isLoading = true
    Logger.workspace.info("打开工作区: \(url.path, privacy: .public)")
    scanTask = Task.detached(priority: .userInitiated) { [weak self] in
      let tree = Self.scan(url: url, depth: 0)
      // 转强引用（let）：消除“并发代码捕获 var self”的 Swift 6 预警
      guard !Task.isCancelled, let self else { return }
      await MainActor.run {
        self.root = tree
        self.isLoading = false
      }
    }
  }

  /// 递归扫描：跳过隐藏文件；过滤不受支持的类型；无可见内容的目录不展示。
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
            switch node.kind {
            case .other:
              return false
            case .folder:
              return !(node.children?.isEmpty ?? true)
            default:
              return true
            }
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
