import Foundation
import os

/// AI 会话仓库（v1.5 方案 A，App 级单实例）：全部线程集中存全局文件
/// （`Application Support/MarkPDF/ai-sessions.json`），磁盘的唯一写者。
///
/// 为什么不再按工作区存 `.markpdf/ai-sessions.json`：会话是「文件的属性」而非
/// 「工作区的属性」——同一文件经不同工作区层级（/a 与 /a/b）打开时，
/// 按工作区存会读不到彼此、各自演化成两条分叉线程（用户实测）。
///
/// 线程键：文件线程 = 解析符号链接后的绝对路径；工作区通用线程 = 工作区根绝对路径；
/// 无工作区窗口的通用线程 = 空串（内存态，不落盘）。
/// 多窗口下各 AIChatStore 只读写自己的线程，仓库合并后整体写出（互不清空）
@MainActor
final class AISessionRepository: ObservableObject {
  /// 内存态线程表（键见类型注释）
  private var sessions: [String: AISessionStore.StoredSession] = [:]
  /// 磁盘损坏：禁写回防覆盖（UI 经 storageError 提示）
  private(set) var isBroken = false
  @Published var storageError: String?
  private let debouncer = Debouncer(interval: 0.5)
  private var didLoad = false

  /// 迁移过的工作区（同一进程内不重复扫）
  private var migratedRoots: Set<String> = []

  init() {
    load()
  }

  // MARK: - 读

  private func load() {
    guard !didLoad else { return }
    didLoad = true
    do {
      for session in try AISessionStore.loadGlobal() {
        guard let key = session.docPath, !key.isEmpty else { continue }
        sessions[key] = session
      }
    } catch {
      isBroken = true
      storageError = error.localizedDescription
      Logger.ai.error("AI 会话载入失败: \(String(describing: error), privacy: .public)")
    }
  }

  func session(for key: String) -> AISessionStore.StoredSession? {
    guard !key.isEmpty else { return nil }
    return sessions[key]
  }

  // MARK: - 写

  /// 更新一条线程（空消息表示删除）；防抖落盘
  func update(_ session: AISessionStore.StoredSession, for key: String) {
    guard !key.isEmpty else { return }  // 无工作区窗口的通用线程：内存态
    if session.messages.isEmpty {
      sessions.removeValue(forKey: key)
    } else {
      var stored = session
      stored.docPath = key
      sessions[key] = stored
    }
    schedulePersist()
  }

  func schedulePersist() {
    debouncer.schedule { [weak self] in
      self?.persist()
    }
  }

  /// 立即落盘（退出/关窗前）
  func flush() {
    debouncer.cancel()
    persist()
  }

  private func persist() {
    guard !isBroken else { return }
    do {
      try AISessionStore.saveGlobal(Array(sessions.values))
    } catch {
      Logger.ai.error("AI 会话落盘失败: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: - 迁移（旧版工作区存储 → 全局）

  /// 打开工作区时把 `{root}/.markpdf/ai-sessions.json` 并入全局存储：
  /// 旧相对键转绝对、通用线程键转工作区根；同键按 updatedAt 合并（旧消息在前）。
  /// 迁移完成后原文件改名归档（不删，可回溯）
  func migrateWorkspaceStoreIfNeeded(root: URL) {
    let rootKey = root.standardizedFileURL.resolvingSymlinksInPath().path
    guard !isBroken, !migratedRoots.contains(rootKey) else { return }
    let legacyURL = AISessionStore.fileURL(workspaceRoot: root)
    guard FileManager.default.fileExists(atPath: legacyURL.path) else {
      migratedRoots.insert(rootKey)
      return
    }
    let legacy: [AISessionStore.StoredSession]
    do {
      legacy = try AISessionStore.load(workspaceRoot: root)
    } catch {
      // 损坏的旧文件：提示但不阻断（全局存储照常工作），不改名以便用户自查
      storageError = error.localizedDescription
      migratedRoots.insert(rootKey)
      Logger.ai.error("AI 会话迁移失败（旧文件损坏）: \(String(describing: error), privacy: .public)")
      return
    }
    migratedRoots.insert(rootKey)
    for session in legacy {
      let key = Self.migratedKey(for: session.docPath, root: root)
      guard !key.isEmpty else { continue }
      if let existing = sessions[key] {
        sessions[key] = Self.merge(existing, session, key: key)
      } else {
        var stored = session
        stored.docPath = key
        sessions[key] = stored
      }
    }
    // 原文件改名归档：下次打开不再迁移，且数据可回溯
    let archived = legacyURL.deletingLastPathComponent()
      .appendingPathComponent("ai-sessions.migrated.json")
    try? FileManager.default.removeItem(at: archived)
    do {
      try FileManager.default.moveItem(at: legacyURL, to: archived)
    } catch {
      Logger.ai.error("旧会话文件归档失败: \(String(describing: error), privacy: .public)")
    }
    Logger.ai.info("AI 会话迁移完成: \(legacy.count) 条线程并入全局存储")
    schedulePersist()
  }

  /// 旧键（相对工作区根 / nil 通用线程）→ 新键（绝对路径 / 工作区根路径）
  nonisolated static func migratedKey(for docPath: String?, root: URL) -> String {
    let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
    guard let docPath, !docPath.isEmpty else { return rootURL.path }
    if docPath.hasPrefix("/") {
      return URL(fileURLWithPath: docPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
    return rootURL.appendingPathComponent(docPath).standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// 同键两条线程合并：较旧者消息在前；摘要沿用较新一方（覆盖下标按旧者消息数平移），
  /// 较新方无摘要则保留旧摘要（旧者位于头部，下标无需平移）
  nonisolated static func merge(
    _ lhs: AISessionStore.StoredSession,
    _ rhs: AISessionStore.StoredSession,
    key: String
  ) -> AISessionStore.StoredSession {
    let (older, newer) = lhs.updatedAt <= rhs.updatedAt ? (lhs, rhs) : (rhs, lhs)
    var merged = AISessionStore.StoredSession(
      docPath: key,
      messages: older.messages + newer.messages,
      updatedAt: newer.updatedAt
    )
    if let summary = newer.rollingSummary {
      merged.rollingSummary = summary
      merged.summarizedCount = min((newer.summarizedCount ?? 0) + older.messages.count, merged.messages.count)
    } else {
      merged.rollingSummary = older.rollingSummary
      merged.summarizedCount = older.summarizedCount
    }
    return merged
  }
}
