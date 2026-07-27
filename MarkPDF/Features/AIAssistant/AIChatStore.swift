import Foundation
import os

/// AI 助手上下文采集源（FR-AI.2）：闭包包由 ContentView 接线，测试注入假实现。
/// md 选区经桥异步（超时回 nil）；其余同步取自各 Store
struct AIContextSources {
  var isPDFActive: () -> Bool = { false }
  /// PDF 选区（已 normalize）；无选区 nil
  var pdfSelection: () -> String? = { nil }
  /// md 选区（经桥；超时/未就绪回 nil）
  var mdSelection: (@escaping (String?) -> Void) -> Void = { $0(nil) }
  /// 当前文档（名字 + 全文，按传入字符预算提取——大 PDF 逐页早停）；无激活文档 nil
  var activeDocument: (Int) -> (name: String, text: String)? = { _ in nil }
  /// 当前文档的结构切节（超预算时两遍路由用）；无结构/无文档 nil
  var documentSections: () -> [DocumentSection]? = { nil }
  /// 工作区根与文件清单（v1.3 工具执行与 system 提示用）
  var workspaceFiles: () -> (root: URL?, files: [URL]) = { (nil, []) }
}

/// AI 助手对话状态机（FR-AI.2 v1.3）：agent 工具调用循环——模型自主决定
/// 是否检索工作区、用什么关键词；三重终止（自然停止/轮数上限/用户取消）。
/// 上下文三层管理：L1 最近原文 + L2 滚动摘要 + L3 全量归档（仅 UI/落盘）。
@MainActor
final class AIChatStore: ObservableObject {
  /// 一次工具调用的 UI 活动（折叠 chip：运行中 → 结果摘要）
  struct ToolActivity: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let argsSummary: String
    var resultSummary: String?
    var isRunning = true
  }

  struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: AIChatMessage.Role
    var content: String
    var isStreaming = false
    /// 用户点停止后保留的部分回复标记
    var wasCancelled = false
    /// 该轮实际附带的上下文摘要（user 消息行小字）
    var contextSummary: String?
    /// 原始问题（历史轮送此而非带上下文块的完整消息；重试复用）
    var promptQuestion: String?
    /// 本条回复过程中的工具调用活动（agent 循环；跨提问只留摘要不进模型历史）
    var toolActivities: [ToolActivity] = []
  }

  enum Phase: Equatable {
    case idle
    case streaming
    case failed(String)
  }

  /// 单会话线程（FR-AI.3 + v1.3 上下文分层）
  private struct Thread {
    var messages: [ChatMessage] = []
    /// L2 滚动摘要（更早轮次的压缩；随会话文件持久化）
    var rollingSummary: String?
    /// messages 中已并入摘要的前缀条数（历史组装从此下标起送原文）
    var summarizedCount = 0
  }

  @Published private(set) var messages: [ChatMessage] = []
  @Published private(set) var phase: Phase = .idle
  /// 当前线程归属（面板头显示：文档名 / nil = 工作区通用）
  @Published private(set) var activeDocName: String?
  /// 会话文件损坏提示（FR-AI.3 不静默吞；损坏期间禁写回防覆盖）
  @Published var storageError: String?
  /// 有工作区才持久（草稿/无工作区内存态，面板提示不持久）
  var isPersistent: Bool { workspaceRoot != nil && !storageBroken }

  /// 面板头部徽标（Provider · 模型）；无可用 Provider 为空串
  var providerBadge: String {
    guard let selection = settings.chatSelection else { return "" }
    return "\(selection.kind.title) · \(selection.model)"
  }

  var contextSources = AIContextSources()

  /// agent 循环轮数上限（超限后最后一轮不带 tools，模型只能作答）
  static let maxToolTurns = 6
  /// 单轮工具结果总量上限（字符）
  static let toolResultsBudgetPerTurn = 12_000

  private let settings: AISettingsStore
  private let service: AIService
  private var streamTask: Task<Void, Never>?
  /// 流式增量缓冲（节流落 @Published，防每秒几十次全面板重渲）
  private var streamBuffer = ""
  private var flushScheduled = false
  /// 后台压缩任务（历史超预算时旧轮次并入滚动摘要；不阻塞当轮）
  private var compactionTask: Task<Void, Never>?
  /// 压缩失败后间隔一轮再试
  private var skipCompactionOnce = false

  // 会话按文档隔离（FR-AI.3 v1.2）：key = 文档绝对路径（"" = 工作区通用线程）。
  // v1.4.1 起统一绝对路径——同一文件从工作区/外部打开共享线程；旧版相对 key 载入时迁移
  private var threads: [String: Thread] = [:]
  private var activeDocKey = ""
  private var workspaceRoot: URL?
  private var storageBroken = false
  private let persistDebouncer = Debouncer(interval: 0.5)

  init(settings: AISettingsStore, service: AIService) {
    self.settings = settings
    self.service = service
  }

  // MARK: - 工作区 / 文档线程（FR-AI.3）

  /// 工作区变化：flush 旧工作区 → 载入新工作区会话（损坏弹错并禁写回）
  func workspaceDidChange(root: URL?) {
    let newRoot = root?.standardizedFileURL
    guard newRoot?.path != workspaceRoot?.path else { return }
    flush()
    streamTask?.cancel()
    streamTask = nil
    compactionTask?.cancel()
    workspaceRoot = newRoot
    storageBroken = false
    threads = [:]
    messages = []
    phase = .idle
    guard let newRoot else { return }
    // 旧版相对 key 迁移为绝对路径；同一文件若曾按相对/绝对双键各存一条，按时间合并
    var didMigrate = false
    do {
      var keyDates: [String: Date] = [:]
      for session in try AISessionStore.load(workspaceRoot: newRoot) {
        if let docPath = session.docPath, !docPath.isEmpty, !docPath.hasPrefix("/") {
          didMigrate = true
        }
        let key = Self.migratedKey(for: session.docPath, root: newRoot)
        let incoming = Thread(
          messages: session.messages.map(ChatMessage.init(stored:)),
          rollingSummary: session.rollingSummary,
          summarizedCount: session.summarizedCount ?? 0
        )
        if var existing = threads[key], !existing.messages.isEmpty, !incoming.messages.isEmpty {
          // 合并：较旧者消息在前；摘要沿用较新一方（其覆盖下标按旧者消息数平移），
          // 较新一方无摘要则保留旧摘要（旧者位于合并数组头部，下标无需平移）
          let existingIsOlder = (keyDates[key] ?? .distantPast) <= session.updatedAt
          let (older, newer) = existingIsOlder ? (existing, incoming) : (incoming, existing)
          existing.messages = older.messages + newer.messages
          if let newSummary = newer.rollingSummary {
            existing.rollingSummary = newSummary
            existing.summarizedCount = min(newer.summarizedCount + older.messages.count, existing.messages.count)
          } else {
            existing.rollingSummary = older.rollingSummary
            existing.summarizedCount = older.summarizedCount
          }
          threads[key] = existing
          keyDates[key] = max(keyDates[key] ?? .distantPast, session.updatedAt)
          didMigrate = true
        } else if threads[key]?.messages.isEmpty != false {
          threads[key] = incoming
          keyDates[key] = session.updatedAt
        }
      }
    } catch {
      storageBroken = true
      storageError = error.localizedDescription
      Logger.ai.error("AI 会话载入失败: \(String(describing: error), privacy: .public)")
    }
    messages = threads[activeDocKey]?.messages ?? []
    // 迁移/合并立即落盘（格式收敛为绝对路径键，不等下一次消息变化或退出）——
    // 必须在 messages 恢复之后：persistNow 会先 storeActiveThreadMessages，
    // 若在此前落盘，载入前的空 messages 会把刚合并的激活线程抹成空（实锤丢数据）
    if didMigrate {
      persistNow()
    }
  }

  /// 激活文档变化：切换会话线程（同 key 幂等；流式途中切换取消在途——语境已变）
  func bindDocument(_ url: URL?) {
    let key = docKey(for: url)
    guard key != activeDocKey else { return }
    if phase == .streaming { cancel() }
    storeActiveThreadMessages()
    activeDocKey = key
    activeDocName = url?.lastPathComponent
    messages = threads[key]?.messages ?? []
    phase = .idle
  }

  /// 退出/切工作区前立即落盘
  func flush() {
    persistDebouncer.cancel()
    persistNow()
  }

  private func docKey(for url: URL?) -> String {
    guard let url else { return "" }
    // 统一绝对路径：同一文件从工作区（旧版为相对路径）或外部打开都是同一条线程
    return url.standardizedFileURL.path
  }

  /// 旧版 key（相对工作区根）迁移为绝对路径；nil/空 = 工作区通用线程（""）
  static func migratedKey(for docPath: String?, root: URL) -> String {
    guard let docPath, !docPath.isEmpty else { return "" }
    if docPath.hasPrefix("/") { return docPath }
    return root.appendingPathComponent(docPath).standardizedFileURL.path
  }

  private func storeActiveThreadMessages() {
    var thread = threads[activeDocKey] ?? Thread()
    thread.messages = messages
    threads[activeDocKey] = thread
  }

  /// 消息变化统一收口：回写线程表 + 防抖落盘
  private func syncActiveThread() {
    storeActiveThreadMessages()
    guard isPersistent else { return }
    persistDebouncer.schedule { [weak self] in
      self?.persistNow()
    }
  }

  private func persistNow() {
    guard let workspaceRoot, isPersistent else { return }
    storeActiveThreadMessages()
    let sessions = threads.compactMap { key, thread -> AISessionStore.StoredSession? in
      guard !thread.messages.isEmpty else { return nil }
      return AISessionStore.StoredSession(
        docPath: key.isEmpty ? nil : key,
        messages: thread.messages.map(\.stored),
        updatedAt: Date(),
        rollingSummary: thread.rollingSummary,
        summarizedCount: thread.summarizedCount
      )
    }
    do {
      try AISessionStore.save(sessions, workspaceRoot: workspaceRoot)
    } catch {
      Logger.ai.error("AI 会话落盘失败: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: - 意图

  func send(_ question: String) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, phase != .streaming else { return }
    // 首次使用 AI 前隐私告知（手动动作，允许弹窗）
    guard AIPrivacyGate.ensureAcknowledged(store: settings) else { return }
    guard let selection = settings.chatSelection else {
      phase = .failed(String(localized: "未启用任何 AI Provider，请到 设置 → AI 配置并启用"))
      return
    }
    phase = .streaming
    compactIfNeeded(resolved: selection)
    streamTask = Task { [weak self] in
      await self?.prepareAndRun(question: trimmed, resolved: selection)
    }
  }

  func cancel() {
    streamTask?.cancel()
    streamTask = nil
    finalizeStreaming(cancelled: true)
    phase = .idle
  }

  /// 失败/停止后重发最后一个问题（上下文按重发时现场重新采集，NFR-4「当次选择」）
  func retry() {
    guard phase != .streaming,
      let lastQuestion = messages.last(where: { $0.role == .user })?.promptQuestion
    else { return }
    // 移除失败尾巴：最后一条 user 及其后的所有消息（send 会重新 append）
    if let index = messages.lastIndex(where: { $0.role == .user }) {
      messages.removeSubrange(index...)
      syncActiveThread()
    }
    phase = .idle
    send(lastQuestion)
  }

  func newSession() {
    streamTask?.cancel()
    streamTask = nil
    messages = []
    streamBuffer = ""
    phase = .idle
    threads[activeDocKey] = Thread()
    syncActiveThread()
  }

  // MARK: - 上下文压缩（L2 滚动摘要，后台不阻塞当轮）

  private func compactIfNeeded(resolved: AISettingsStore.ResolvedModel) {
    guard compactionTask == nil, !skipCompactionOnce else {
      skipCompactionOnce = false
      return
    }
    let thread = threads[activeDocKey] ?? Thread()
    let summarized = min(thread.summarizedCount, messages.count)
    let live = Array(messages[summarized...])
    let liveChars = live.reduce(0) { $0 + $1.content.count }
    let budget = AIModelContext.historyCharBudget(contextTokens: resolved.contextTokens)
    // 触发：字符比例主导（超历史预算）；条数上限为下限保护（长对话短消息也归档）
    guard liveChars > budget || live.count > AIContextBuilder.historyMessageCap else { return }

    // 压缩范围 = 滚出保留区的旧增量（v1.4）：近期原文完整保留，只压新滚出部分（不重压已压过的）
    let liveMessages = live.map { message in
      AIChatMessage(role: message.role, content: message.role == .user ? (message.promptQuestion ?? message.content) : message.content)
    }
    let preserveChars = AIModelContext.preserveRecentChars(contextTokens: resolved.contextTokens)
    var toCompact = AIContextBuilder.splitForPreservation(liveMessages, preserveChars: preserveChars).toCompact
    if toCompact.isEmpty, live.count > AIContextBuilder.historyMessageCap {
      // 条数触发但字符量都在保留区内：把超 cap 的最旧轮次并入摘要（分割点仍对齐轮次边界）
      var index = live.count - AIContextBuilder.historyMessageCap
      while index < liveMessages.count,
        !(liveMessages[index].role == .user && liveMessages[index - 1].role != .user) {
        index += 1
      }
      toCompact = Array(liveMessages[..<index])
    }
    guard !toCompact.isEmpty else { return }
    let compactCount = toCompact.count

    let existing = thread.rollingSummary
    let inputChars = toCompact.reduce(0) { $0 + $1.content.count } + (existing?.count ?? 0)
    let docKey = activeDocKey
    compactionTask = Task { [weak self] in
      guard let self else { return }
      defer { self.compactionTask = nil }
      do {
        let summary = try await self.service.complete(
          kind: resolved.kind,
          config: resolved.config,
          model: resolved.model,
          messages: AIContextBuilder.compactionMessages(existingSummary: existing, turns: toCompact),
          maxTokens: AIContextBuilder.compactionMaxTokens(forInputChars: inputChars)
        )
        guard !Task.isCancelled, var thread = self.threads[docKey] else { return }
        var compactedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // 锚点代码级兜底（学 Cline ensureFilesSection）：摘要漏掉的锚点由代码追加，防有损压缩丢引用
        let sourceAnchors = AIContextBuilder.extractAnchors(
          in: toCompact.map(\.content).joined(separator: "\n") + "\n" + (existing ?? "")
        )
        let missing = sourceAnchors.filter { !compactedSummary.contains($0) }
        if !missing.isEmpty {
          compactedSummary += "\n\nAnchors mentioned: " + missing.joined(separator: ", ")
        }
        thread.rollingSummary = compactedSummary
        thread.summarizedCount = min(summarized + compactCount, thread.messages.count)
        self.threads[docKey] = thread
        self.persistDebouncer.schedule { [weak self] in self?.persistNow() }
        Logger.ai.debug("历史压缩完成: 并入 \(compactCount) 条（\(inputChars) 字），摘要 \(summary.count) 字")
      } catch {
        // 失败降级：维持硬截断（historyMessages 自带），间隔一轮再试
        self.skipCompactionOnce = true
        Logger.ai.error("历史压缩失败: \((error as? AIServiceError)?.logSafeDescription ?? "未知错误", privacy: .public)")
      }
    }
  }

  // MARK: - 组装与 agent 循环

  private func prepareAndRun(question: String, resolved: AISettingsStore.ResolvedModel) async {
    let includeSelection = settings.settings.contextIncludeSelection
    let includeDocument = settings.settings.contextIncludeDocument
    let toolsEnabled = settings.settings.contextIncludeWorkspace
    // 上下文预算（v1.3）：窗口与回复上限均为用户设定值
    let replyTokens = AIModelContext.effectiveReplyTokens(
      userSetting: settings.settings.chatMaxReplyTokens,
      contextTokens: resolved.contextTokens
    )
    let documentBudget = AIModelContext.documentCharBudget(
      contextTokens: resolved.contextTokens,
      replyTokens: replyTokens
    )

    // ① 选区
    var selectionText: String?
    if includeSelection {
      if contextSources.isPDFActive() {
        selectionText = contextSources.pdfSelection()
      } else {
        selectionText = await withCheckedContinuation { continuation in
          contextSources.mdSelection { continuation.resume(returning: $0) }
        }
      }
    }
    guard !Task.isCancelled else { return }

    // ② 当前文档：预算内整文；超预算且可切节 → 两遍路由（失败回退头部截断）
    var document = includeDocument ? contextSources.activeDocument(documentBudget + 1) : nil
    var annotation: String?
    if let doc = document, doc.text.count > documentBudget,
      let sections = contextSources.documentSections(), sections.count > 1,
      let routed = await routeSections(question: question, sections: sections, resolved: resolved, budget: documentBudget) {
      document = (name: doc.name, text: routed.text)
      annotation = routed.note
    }
    guard !Task.isCancelled else { return }

    let built = AIContextBuilder.buildUserMessage(
      question: question,
      selection: selectionText,
      document: document,
      documentBudget: documentBudget,
      documentAnnotation: annotation
    )

    // UI 行
    var userRow = ChatMessage(role: .user, content: question)
    userRow.contextSummary = built.summary
    userRow.promptQuestion = question
    messages.append(userRow)
    var assistantRow = ChatMessage(role: .assistant, content: "")
    assistantRow.isStreaming = true
    messages.append(assistantRow)
    syncActiveThread()

    // 组装 outgoing：system(+工具指引) + L2 摘要 + L1 历史原文 + 当轮 user
    let thread = threads[activeDocKey] ?? Thread()
    var systemPrompt = AIContextBuilder.systemPrompt()
    let workspace = contextSources.workspaceFiles()
    if toolsEnabled {
      systemPrompt += "\n\n" + AIWorkspaceTools.systemHint(fileNames: workspace.files.map(\.lastPathComponent))
    }
    let historySource = Array(messages.dropLast(2)[min(thread.summarizedCount, max(messages.count - 2, 0))...])
      .map { message in
        AIChatMessage(role: message.role, content: message.role == .user ? (message.promptQuestion ?? message.content) : message.content)
      }
    var outgoing: [AIChatMessage] = [.system(systemPrompt)]
    outgoing += AIContextBuilder.historyMessages(
      historySource,
      rollingSummary: thread.rollingSummary,
      charBudget: AIModelContext.historyCharBudget(contextTokens: resolved.contextTokens)
    )
    outgoing.append(.user(built.userMessage))

    await runAgentLoop(
      outgoing: outgoing,
      resolved: resolved,
      replyTokens: replyTokens,
      toolsEnabled: toolsEnabled,
      workspaceRoot: workspace.root,
      workspaceFiles: workspace.files
    )
  }

  /// agent 循环：流式作答；模型请求工具 → 执行 → 结果回传 → 下一轮；
  /// 三重终止：模型停止调用 / maxToolTurns 上限（末轮不带 tools）/ 用户取消
  private func runAgentLoop(
    outgoing initial: [AIChatMessage],
    resolved: AISettingsStore.ResolvedModel,
    replyTokens: Int,
    toolsEnabled: Bool,
    workspaceRoot: URL?,
    workspaceFiles: [URL]
  ) async {
    var outgoing = initial
    var turns = 0
    var totalCalls = 0
    var executedResults: [String: String] = [:]  // name+args → result（重复调用去重）
    var streamedBase = 0  // 本轮开始时 assistant 消息的文本长度（提取当轮新文本）

    do {
      while true {
        let useTools = toolsEnabled && turns < Self.maxToolTurns
        var received: [AIToolCall] = []
        streamBuffer = ""
        let stream = service.stream(
          kind: resolved.kind,
          config: resolved.config,
          model: resolved.model,
          messages: outgoing,
          maxTokens: replyTokens,
          tools: useTools ? AIWorkspaceTools.definitions : nil
        )
        for try await event in stream {
          switch event {
          case .text(let delta):
            streamBuffer += delta
            scheduleFlush()
          case .toolCalls(let calls):
            received = calls
          }
        }
        guard !Task.isCancelled else { return }
        flushNow()

        if received.isEmpty {
          finalizeStreaming(cancelled: false)
          phase = .idle
          streamTask = nil
          return
        }

        // 本轮 assistant（文本 + 调用）入 outgoing；UI 挂活动 chips
        let fullText = messages.last?.content ?? ""
        let turnText = String(fullText.dropFirst(min(streamedBase, fullText.count)))
        streamedBase = fullText.count
        outgoing.append(AIChatMessage(role: .assistant, content: turnText, toolCalls: received))

        var turnBudget = Self.toolResultsBudgetPerTurn
        for (offset, call) in received.enumerated() {
          guard !Task.isCancelled else { return }
          let activityIndex = appendActivity(for: call)
          let dedupeKey = call.name + call.arguments
          let result: String
          if let previous = executedResults[dedupeKey] {
            result = "Duplicate call (identical arguments). Previous result:\n" + String(previous.prefix(500))
          } else {
            let root = workspaceRoot
            let files = workspaceFiles
            result = await Task.detached(priority: .userInitiated) {
              AIWorkspaceTools.execute(call: call, workspaceRoot: root, files: files)
            }.value
            executedResults[dedupeKey] = result
          }
          var clipped = String(result.prefix(max(turnBudget, 500)))
          turnBudget = max(turnBudget - clipped.count, 0)
          completeActivity(at: activityIndex, result: clipped)
          totalCalls += 1
          if offset == received.indices.last {
            // 每轮状态行（PaperQA2 状态注入）：并入最后一个工具结果尾部——预算感知收敛且不破坏消息交替
            clipped += "\n\n[Status] turn \(turns + 1)/\(Self.maxToolTurns) · \(totalCalls) tool calls used · answer directly when you have enough evidence"
          }
          outgoing.append(.toolResult(id: call.id, content: clipped))
        }
        syncActiveThread()
        turns += 1
        Logger.ai.debug("agent 轮次 \(turns): 执行 \(received.count) 个工具调用")
      }
    } catch is CancellationError {
      // cancel() 已收尾
    } catch {
      guard !Task.isCancelled else { return }
      flushNow()
      finalizeStreaming(cancelled: false)
      let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      let safe = (error as? AIServiceError)?.logSafeDescription ?? "未知错误"
      Logger.ai.error("AI 对话失败: \(safe, privacy: .public)")
      phase = .failed(description)
    }
    streamTask = nil
  }

  /// 挂载运行中的工具活动 chip；返回其在当前 assistant 消息中的下标
  private func appendActivity(for call: AIToolCall) -> Int? {
    guard let last = messages.indices.last, messages[last].role == .assistant else { return nil }
    let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
    let argsSummary = ["query", "path", "section"]
      .compactMap { key in (arguments[key] as? String).map { "\($0)" } }
      .joined(separator: " · ")
    messages[last].toolActivities.append(ToolActivity(name: call.name, argsSummary: argsSummary))
    return messages[last].toolActivities.indices.last
  }

  private func completeActivity(at index: Int?, result: String) {
    guard let index, let last = messages.indices.last, messages[last].role == .assistant,
      messages[last].toolActivities.indices.contains(index) else { return }
    messages[last].toolActivities[index].isRunning = false
    let firstLine = result.split(separator: "\n").first.map(String.init) ?? ""
    messages[last].toolActivities[index].resultSummary = String(firstLine.prefix(80))
  }

  /// 两遍路由第一遍：目录摘要给模型选节；任何失败返回 nil（调用方回退头部截断）
  private func routeSections(
    question: String,
    sections: [DocumentSection],
    resolved: AISettingsStore.ResolvedModel,
    budget: Int
  ) async -> (text: String, note: String)? {
    do {
      let reply = try await service.complete(
        kind: resolved.kind,
        config: resolved.config,
        model: resolved.model,
        messages: AISectionRouter.routingMessages(
          question: question,
          outline: DocumentSectioner.outlineDigest(sections)
        ),
        maxTokens: AISectionRouter.maxTokens
      )
      guard let picked = AISectionRouter.parsePicked(reply, sectionCount: sections.count) else { return nil }
      let text = DocumentSectioner.assemble(sections: sections, picked: picked, budget: budget)
      guard !text.isEmpty else { return nil }
      Logger.ai.debug("路由选节: \(picked.count) 节 / 共 \(sections.count) 节")
      return (text, String(localized: "已选 \(picked.count) 节"))
    } catch {
      Logger.ai.error("路由选节失败，回退头部截断: \((error as? AIServiceError)?.logSafeDescription ?? "未知错误", privacy: .public)")
      return nil
    }
  }

  /// 增量节流（~80ms）：缓冲攒批后一次性落最后一条消息
  private func scheduleFlush() {
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.flushScheduled = false
      self?.flushNow()
    }
  }

  private func flushNow() {
    guard !streamBuffer.isEmpty, let last = messages.indices.last, messages[last].role == .assistant else { return }
    messages[last].content += streamBuffer
    streamBuffer = ""
  }

  /// 流式收尾：冲刷缓冲、落定最后一条 assistant；零增量的取消消息整体移除
  ///（空 assistant 进历史会让 Anthropic 非空校验 400）
  private func finalizeStreaming(cancelled: Bool) {
    flushNow()
    defer { syncActiveThread() }
    guard let last = messages.indices.last, messages[last].role == .assistant, messages[last].isStreaming else { return }
    messages[last].isStreaming = false
    messages[last].wasCancelled = cancelled
    // 运行中的活动一并落定（取消场景）
    for index in messages[last].toolActivities.indices {
      messages[last].toolActivities[index].isRunning = false
    }
    if cancelled, messages[last].content.isEmpty, messages[last].toolActivities.isEmpty {
      messages.remove(at: last)
    }
  }
}

// MARK: - 落盘转换（FR-AI.3）

extension AIChatStore.ChatMessage {
  init(stored: AISessionStore.StoredMessage) {
    self.init(role: AIChatMessage.Role(rawValue: stored.role) ?? .assistant, content: stored.content)
    contextSummary = stored.contextSummary
    promptQuestion = stored.promptQuestion
    wasCancelled = stored.wasCancelled ?? false
    toolActivities = (stored.toolActivities ?? []).map {
      var activity = AIChatStore.ToolActivity(name: $0.name, argsSummary: $0.argsSummary)
      activity.resultSummary = $0.resultSummary
      activity.isRunning = false
      return activity
    }
  }

  var stored: AISessionStore.StoredMessage {
    AISessionStore.StoredMessage(
      role: role.rawValue,
      content: content,
      contextSummary: contextSummary,
      promptQuestion: promptQuestion,
      wasCancelled: wasCancelled ? true : nil,
      toolActivities: toolActivities.isEmpty ? nil : toolActivities.map {
        AISessionStore.StoredToolActivity(name: $0.name, argsSummary: $0.argsSummary, resultSummary: $0.resultSummary)
      }
    )
  }
}
