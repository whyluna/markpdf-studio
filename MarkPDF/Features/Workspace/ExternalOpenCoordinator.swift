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
  /// 冷启动是否由外部打开唤起（onAppear 据此跳过工作区现场恢复，功能不降级）
  var hasPendingExternalOpen: Bool { !pendingURLs.isEmpty }
  /// 会话级「仅打开文件」记忆：同一文件夹不重复弹询问
  private var declinedFolders: Set<String> = []
  /// ask 流程串行化（FR-7.4 审查修复）：runModal 是同步阻塞且会跑嵌套事件循环，
  /// 期间到达的 onOpenURL 只入队不嵌套弹窗（多文件拖 Dock 时弹窗叠弹窗、
  /// 后开文件会被随后 switchWorkspace 整体替换现场而静默撤掉），处理完依次放行
  private var pendingAsks: [(folder: URL, folderKey: String, file: URL)] = []
  private var isAsking = false
  /// ask 弹窗执行体（测试替换避免 runModal；生产实现为系统弹窗 + 沙盒授权面板）
  lazy var presentAsk: (URL, String, URL) -> Void = { [weak self] folder, folderKey, file in
    self?.askToOpenWorkspace(folder: folder, folderKey: folderKey, file: file)
  }
  /// 应用已激活：ask 弹窗必须等激活后再弹——启动早期（首窗 onAppear / AppleEvent 分发栈内）
  /// runModal 会以非首按钮立即返回，把询问静默记成「仅打开文件」（用户根本没看到弹窗，实测）
  private var appBecameActive = false

  init() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.appDidBecomeActive()
      }
    }
  }

  /// 应用激活（didBecomeActive 通知或测试调用）：此后才允许弹 ask 窗口
  func appDidBecomeActive() {
    guard !appBecameActive else { return }
    appBecameActive = true
    drainAskQueue()
  }

  // 接线（WindowRootView）：v1.5 起路由经 WindowCoordinator——
  // 已打开该文件或其工作区包含它 → 聚焦该窗口；否则新开单文件窗口
  var openFileTab: ((URL) -> Void)?
  /// 单窗口时代的当前工作区根（测试与回退用；多窗口下由 workspaceRootPaths 接管）
  var currentRootPath: (() -> String?)?
  /// 全部窗口的工作区根（v1.5：任一窗口的工作区包含该文件即算「工作区内」，不再弹询问）
  var workspaceRootPaths: (() -> [String])?
  var switchWorkspaceTo: ((URL) -> Void)?
  /// 「设为工作区」被接受：把承接该文件的窗口升级为工作区窗口（v1.5；未接线则回退旧行为）
  var upgradeToWorkspace: ((URL, URL) -> Void)?

  /// 判定用的工作区根集合（多窗口优先，回退单根）
  private func rootPaths() -> [String] {
    if let workspaceRootPaths { return workspaceRootPaths() }
    return [currentRootPath?()].compactMap { $0 }
  }

  /// 多窗口判定：任一窗口的工作区包含该文件夹即「工作区内」
  nonisolated static func decide(folderKey: String, rootPaths: [String], declinedFolders: Set<String>) -> Decision {
    let folder = URL(fileURLWithPath: folderKey)
    // 「工作区内」= 同根或根的后代（/ws/notes 属于 /ws）：仅比相等会把子目录文件
    // 误判成异根，用户确认后 switchWorkspace 反而把工作区收窄到子目录
    if rootPaths.contains(where: { folder.isWithinWorkspace(rootPath: $0) }) {
      return .openInCurrentWorkspace
    }
    if declinedFolders.contains(folderKey) { return .openBareSilent }
    return .openBareAndAsk
  }

  /// 单根兼容重载
  nonisolated static func decide(folderKey: String, currentRootPath: String?, declinedFolders: Set<String>) -> Decision {
    decide(
      folderKey: folderKey,
      rootPaths: [currentRootPath].compactMap { $0 },
      declinedFolders: declinedFolders
    )
  }

  /// 是否受理外部打开的 URL（纯函数可单测）：目录与 md/pdf/图片白名单之外的类型直接忽略
  nonisolated static func shouldHandle(_ url: URL, isDirectory: Bool) -> Bool {
    switch FileNode.kind(for: url, isDirectory: isDirectory) {
    case .markdown, .pdf, .image: return true
    default: return false
    }
  }

  func handle(_ url: URL) {
    // 白名单过滤（FR-7.4 审查修复）：拖到 Dock 的目录/任意类型不应进标签弹窗
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    guard Self.shouldHandle(url, isDirectory: isDirectory) else {
      Logger.workspace.info("外部打开忽略（目录或非白名单类型）: \(url.lastPathComponent, privacy: .public)")
      return
    }
    guard isReady else {
      // 冷启动双通道去重（AppDelegate.openFiles 与 SwiftUI onOpenURL 可能都送达）：
      // 队列里已有的不重复入队；就绪后的重复投递由路由幂等吸收（已开则聚焦）
      if !pendingURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
        pendingURLs.append(url)
      }
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
      rootPaths: rootPaths(),
      declinedFolders: declinedFolders
    )
    Logger.workspace.info("外部打开: \(file.lastPathComponent, privacy: .public) 决策 \(String(describing: decision), privacy: .public)")
    // 文件本身已获 Finder 授权，先交付（三种决策都立即可见内容）：
    // 工作区内 → 聚焦该窗口开标签；否则新开单文件窗口
    openFileTab?(file)
    guard decision == .openBareAndAsk else { return }
    // 同文件夹的询问只排一次（双通道重复投递 / 多文件同批拖入）
    guard !pendingAsks.contains(where: { $0.folderKey == folderKey }) else { return }
    pendingAsks.append((folder, folderKey, file))
    drainAskQueue()
  }

  /// 依次放行 ask 队列：同一时刻最多一个弹窗；runModal 期间嵌套到达的 ask
  /// 只追加到 pendingAsks（此时 isAsking = true，嵌套 drain 直接返回），本轮结束后继续。
  /// 应用未激活前不弹（启动早期 runModal 会静默返回非首按钮）
  private func drainAskQueue() {
    guard appBecameActive, !isAsking else { return }
    while let next = pendingAsks.first {
      pendingAsks.removeFirst()
      guard Self.shouldPresentAsk(
        folderKey: next.folderKey,
        rootPaths: rootPaths(),
        declinedFolders: declinedFolders
      ) else { continue }
      isAsking = true
      presentAsk(next.folder, next.folderKey, next.file)
      isAsking = false
    }
  }

  /// 排队的 ask 轮到放行时是否还需要弹（纯函数可单测）：
  /// 排队期间已被「仅打开文件」拒绝（同一会话不重复询问）、
  /// 或某窗口工作区已切进该文件夹（同批上一个 ask 被接受）的，跳过
  nonisolated static func shouldPresentAsk(
    folderKey: String, rootPaths: [String], declinedFolders: Set<String>
  ) -> Bool {
    if declinedFolders.contains(folderKey) { return false }
    let folder = URL(fileURLWithPath: folderKey)
    return !rootPaths.contains { folder.isWithinWorkspace(rootPath: $0) }
  }

  /// 单根兼容重载
  nonisolated static func shouldPresentAsk(
    folderKey: String, currentRootPath: String?, declinedFolders: Set<String>
  ) -> Bool {
    shouldPresentAsk(
      folderKey: folderKey,
      rootPaths: [currentRootPath].compactMap { $0 },
      declinedFolders: declinedFolders
    )
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
      Logger.workspace.info("设为工作区询问: 仅打开文件 \(folderKey, privacy: .public)")
      return
    }
    Logger.workspace.info("设为工作区询问: 接受 \(folderKey, privacy: .public)")
    // 沙盒授权面板：预定位到目标文件夹，用户点一下确认即建立文件夹访问权（随后书签持久化）
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = folder
    panel.prompt = String(localized: "设为工作区")
    panel.message = String(localized: "确认将此文件夹设为工作区（沙盒授权，仅需一次）")
    guard panel.runModal() == .OK, let granted = panel.url else { return }
    // v1.5：把承接该文件的窗口就地升级为工作区窗口（其他窗口不受影响）；
    // 未接线（旧路径/测试）则回退「当前窗口切工作区 + 重开文件」
    if let upgradeToWorkspace {
      upgradeToWorkspace(granted, file)
    } else {
      switchWorkspaceTo?(granted)
      // switchWorkspace 会整体替换标签现场（恢复目标工作区自己的快照），切换后重开目标文件
      openFileTab?(file)
    }
  }
}

extension URL {
  /// 是否等于工作区根或位于其内（按路径组件边界比较：/a/b 不命中 /a/b2；
  /// 思路同 TabGroup.swift 的 isDescendant，那是 fileprivate 无法直接复用）。
  /// 两侧均标准化 + 符号链接归一：用户自建 symlink 作工作区根时，
  /// 经解析形态投递的 URL 不应绕过判定（开裸窗/不入槽/图片护栏失守）。
  /// rootPath 为槽位 key（同 WorkspaceStateStore.slotKey，函数内再归一，两种形态都安全）。
  /// 三处共用（FR-7.4 降级链路，改动须同步）：
  /// ExternalOpenCoordinator.decide（同根判定）、MarkdownEditorView.saveImage（图片落盘护栏）、
  /// WorkspaceStateStore.tabsDidChange（异根标签过滤）
  func isWithinWorkspace(rootPath: String) -> Bool {
    let selfPath = standardizedFileURL.resolvingSymlinksInPath().path
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath().path
    return selfPath == normalizedRoot || selfPath.hasPrefix(normalizedRoot + "/")
  }

  /// root 为 URL 的便捷重载（先标准化，/tmp→/private/tmp 等符号链接归一）
  func isWithinWorkspace(root: URL) -> Bool {
    isWithinWorkspace(rootPath: root.standardizedFileURL.path)
  }
}
