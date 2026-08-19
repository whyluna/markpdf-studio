import Foundation
import os

/// AI 会话落盘（FR-AI.3）：v1.5 起全部线程集中存全局文件
/// `Application Support/MarkPDF/ai-sessions.json`（见 AISessionRepository——会话是
/// 文件的属性，按工作区存会让同一文件经不同工作区层级打开时分叉）。
/// `{root}/.markpdf/ai-sessions.json` 为旧格式，仅迁移读取与归档。
/// 多会话（每文件一条线程 + 工作区通用线程）、单会话超 100 条截断、
/// 原子写、损坏抛错不静默吞（UI 弹提示）。
enum AISessionStore {
  static let messageCap = 100

  struct StoredToolActivity: Codable, Equatable {
    var name: String
    var argsSummary: String
    var resultSummary: String?
  }

  struct StoredMessage: Codable, Equatable {
    var role: String
    var content: String
    var contextSummary: String?
    var promptQuestion: String?
    var wasCancelled: Bool?
    /// 工具活动摘要（v1.3 agent 循环；旧文件缺省 decodeIfPresent 兼容）
    var toolActivities: [StoredToolActivity]?
    /// 本条回复挂的变更提案卡片（FR-AI.5/6；UUID 字符串；旧文件缺省兼容）
    var changeSetID: String?

    init(role: String, content: String, contextSummary: String?, promptQuestion: String?, wasCancelled: Bool?, toolActivities: [StoredToolActivity]? = nil, changeSetID: String? = nil) {
      self.role = role
      self.content = content
      self.contextSummary = contextSummary
      self.promptQuestion = promptQuestion
      self.wasCancelled = wasCancelled
      self.toolActivities = toolActivities
      self.changeSetID = changeSetID
    }
  }

  /// 变更提案卡片落盘形态（2026-08-19 持久化）：审查视图（变更段/勾选/状态）随会话
  /// 保存——重启后卡片与「当时改了什么」回看可用；检查点不落盘（撤销时按审查基准重建）
  struct StoredChangeSet: Codable, Equatable {
    var id: String
    var changeSet: AIChangeSet
    var status: AIChangeStore.Status
    /// AIFileChange.id → 审查数据
    var reviews: [String: AIChangeStore.FileReview]
  }

  struct StoredSession: Codable, Equatable {
    /// 归属文档路径（绝对路径；nil = 工作区通用线程。v1.4.1 前为相对工作区根，载入时迁移）
    var docPath: String?
    var messages: [StoredMessage]
    var updatedAt: Date
    /// L2 滚动摘要（v1.3 上下文分层；旧文件缺省兼容）
    var rollingSummary: String?
    /// 已并入摘要的消息前缀条数
    var summarizedCount: Int?
    /// 本线程消息引用的变更提案卡片（FR-AI.5/6；旧文件缺省兼容）
    var changes: [StoredChangeSet]?

    init(docPath: String?, messages: [StoredMessage], updatedAt: Date, rollingSummary: String? = nil, summarizedCount: Int? = nil, changes: [StoredChangeSet]? = nil) {
      self.docPath = docPath
      self.messages = messages
      self.updatedAt = updatedAt
      self.rollingSummary = rollingSummary
      self.summarizedCount = summarizedCount
      self.changes = changes
    }
  }

  struct SessionsFile: Codable, Equatable {
    var version: Int = 1
    var sessions: [StoredSession] = []

    init() {}

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
      sessions = try container.decodeIfPresent([StoredSession].self, forKey: .sessions) ?? []
    }
  }

  enum StoreError: LocalizedError {
    case corrupted(String)

    var errorDescription: String? {
      switch self {
      case .corrupted(let detail):
        String(localized: "AI 会话文件损坏，本次不会向其写回：\(detail)")
      }
    }
  }

  static func fileURL(workspaceRoot: URL) -> URL {
    workspaceRoot.appendingPathComponent(".markpdf/ai-sessions.json")
  }

  // MARK: - 全局存储（TextMate 范式：线程跟文件走）

  /// 全局会话存储目录（Application Support/MarkPDF；工作区外打开的文件——
  /// 沙盒安全不依赖文件夹授权；测试可改写为临时目录）
  static var globalStoreDirectory: URL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MarkPDF", isDirectory: true)

  static func globalFileURL() -> URL {
    globalStoreDirectory.appendingPathComponent("ai-sessions.json")
  }

  /// 读盘：文件不存在返回空；存在但解不出抛 corrupted（调用方弹错并禁写回，防覆盖）
  static func load(workspaceRoot: URL) throws -> [StoredSession] {
    let url = fileURL(workspaceRoot: workspaceRoot)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    do {
      return try JSONDecoder().decode(SessionsFile.self, from: data).sessions
    } catch {
      throw StoreError.corrupted(error.localizedDescription)
    }
  }

  /// 全局存储读盘（同 load 的损坏语义）
  static func loadGlobal() throws -> [StoredSession] {
    let url = globalFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    do {
      return try JSONDecoder().decode(SessionsFile.self, from: data).sessions
    } catch {
      throw StoreError.corrupted(error.localizedDescription)
    }
  }

  /// 旧格式写盘（v1.5 起仅供迁移路径的往返与其测试夹具；生产写入走 saveGlobal）
  static func save(_ sessions: [StoredSession], workspaceRoot: URL) throws {
    let url = fileURL(workspaceRoot: workspaceRoot)
    try write(sessions, to: url)
  }

  /// 全局存储写盘（同 save 的原子写/截断语义）
  static func saveGlobal(_ sessions: [StoredSession]) throws {
    try write(sessions, to: globalFileURL())
  }

  private static func write(_ sessions: [StoredSession], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var file = SessionsFile()
    file.sessions = sessions.map { session in
      var trimmed = session
      trimmed.messages = Array(session.messages.suffix(messageCap))
      return trimmed
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(file)
    try data.write(to: url, options: .atomic)
  }
}
