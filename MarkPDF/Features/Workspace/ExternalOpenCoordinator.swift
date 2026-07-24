import AppKit
import Foundation
import os

/// Finder 直接打开文件（双击 / Open With / 拖 Dock）的路由（FR：直接打开 PDF/md）。
/// 沙盒下 Finder 送来的文件本身即获授权（user-selected），但所在文件夹没有——
/// 扫描文件夹作工作区需用户一次授权（NSOpenPanel 预定位，点一下即可，书签永久记忆）。
@MainActor
final class ExternalOpenCoordinator: ObservableObject {
  /// 路由决策（纯函数可单测）
  enum Decision: Equatable {
    /// 所在文件夹就是当前工作区：直接开标签
    case openInCurrentWorkspace
    /// 异文件夹且本会话未拒绝过：开标签 + 询问是否设为工作区
    case openBareAndAsk
    /// 本会话已拒绝过该文件夹：只开标签不再问
    case openBareSilent
  }

  /// 恢复现场完成前到达的 URL 先入队（冷启动 onOpenURL 与 onAppear 顺序不定）
  private var pendingURLs: [URL] = []
  private(set) var isReady = false
  /// 会话级「仅打开文件」记忆：同一文件夹不重复弹询问
  private var declinedFolders: Set<String> = []

  // ContentView.onAppear 接线（仿 workspaceStore.onOpenFolder 闭包模式）
  var openFileTab: ((URL) -> Void)?
  var currentRootPath: (() -> String?)?
  var switchWorkspaceTo: ((URL) -> Void)?

  nonisolated static func decide(folderKey: String, currentRootPath: String?, declinedFolders: Set<String>) -> Decision {
    if folderKey == currentRootPath { return .openInCurrentWorkspace }
    if declinedFolders.contains(folderKey) { return .openBareSilent }
    return .openBareAndAsk
  }

  func handle(_ url: URL) {
    guard isReady else {
      pendingURLs.append(url)
      return
    }
    route(url)
  }

  /// 恢复现场与闭包接线完成后调用：放行队列
  func markReady() {
    isReady = true
    let queued = pendingURLs
    pendingURLs = []
    queued.forEach { route($0) }
  }

  private func route(_ file: URL) {
    let folder = file.deletingLastPathComponent()
    let folderKey = folder.standardizedFileURL.path
    let decision = Self.decide(
      folderKey: folderKey,
      currentRootPath: currentRootPath?(),
      declinedFolders: declinedFolders
    )
    Logger.workspace.info("外部打开: \(file.lastPathComponent, privacy: .public) 决策 \(String(describing: decision), privacy: .public)")
    // 文件本身已获 Finder 授权，先开标签（三种决策都立即可见内容）
    openFileTab?(file)
    guard decision == .openBareAndAsk else { return }
    askToOpenWorkspace(folder: folder, folderKey: folderKey, file: file)
  }

  private func askToOpenWorkspace(folder: URL, folderKey: String, file: URL) {
    let isMarkdown = FileNode.kind(for: file, isDirectory: false) == .markdown
    let alert = NSAlert()
    alert.messageText = String(localized: "将所在文件夹设为工作区？")
    alert.informativeText = isMarkdown
      ? String(localized: "设为工作区后可使用文件树、图片粘贴、反向链接与全文搜索；自动保存与相对路径图片也需要文件夹访问权限。\n\n下一步会弹出系统授权面板，已定位到该文件夹，点「设为工作区」即可。")
      : String(localized: "设为工作区后可浏览同文件夹的其他文件，标注也会随文件夹记忆。\n\n下一步会弹出系统授权面板，已定位到该文件夹，点「设为工作区」即可。")
    alert.addButton(withTitle: String(localized: "设为工作区…"))
    alert.addButton(withTitle: String(localized: "仅打开文件"))
    guard alert.runModal() == .alertFirstButtonReturn else {
      declinedFolders.insert(folderKey)
      return
    }
    // 沙盒授权面板：预定位到目标文件夹，用户点一下确认即建立文件夹访问权（随后书签持久化）
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = folder
    panel.prompt = String(localized: "设为工作区")
    panel.message = String(localized: "确认将此文件夹设为工作区（沙盒授权，仅需一次）")
    guard panel.runModal() == .OK, let granted = panel.url else { return }
    switchWorkspaceTo?(granted)
    // switchWorkspace 会整体替换标签现场（恢复目标工作区自己的快照），切换后重开目标文件
    openFileTab?(file)
  }
}
