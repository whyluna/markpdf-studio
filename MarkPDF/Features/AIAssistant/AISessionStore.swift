import Foundation
import os

/// AI 会话落盘（FR-AI.3）：按工作区存 `{root}/.markpdf/ai-sessions.json`。
/// 多会话（每文档一条线程 + 工作区通用线程）、单会话超 100 条截断、
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

    init(role: String, content: String, contextSummary: String?, promptQuestion: String?, wasCancelled: Bool?, toolActivities: [StoredToolActivity]? = nil) {
      self.role = role
      self.content = content
      self.contextSummary = contextSummary
      self.promptQuestion = promptQuestion
      self.wasCancelled = wasCancelled
      self.toolActivities = toolActivities
    }
  }

  struct StoredSession: Codable, Equatable {
    /// 归属文档路径（相对工作区根；nil = 工作区通用线程）
    var docPath: String?
    var messages: [StoredMessage]
    var updatedAt: Date
    /// L2 滚动摘要（v1.3 上下文分层；旧文件缺省兼容）
    var rollingSummary: String?
    /// 已并入摘要的消息前缀条数
    var summarizedCount: Int?

    init(docPath: String?, messages: [StoredMessage], updatedAt: Date, rollingSummary: String? = nil, summarizedCount: Int? = nil) {
      self.docPath = docPath
      self.messages = messages
      self.updatedAt = updatedAt
      self.rollingSummary = rollingSummary
      self.summarizedCount = summarizedCount
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

  /// 写盘：建 .markpdf 目录 + 原子写（开发规范 §10）；每会话截到最近 messageCap 条
  static func save(_ sessions: [StoredSession], workspaceRoot: URL) throws {
    let url = fileURL(workspaceRoot: workspaceRoot)
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
