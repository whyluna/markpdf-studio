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
  /// 工作区检索候选（第三层：召回命中文件并切节，后台执行回调主线程）
  var workspaceCandidates: (String, @escaping ([AIWorkspaceRetriever.Candidate]) -> Void) -> Void = { $1([]) }
}

/// AI 助手对话状态机（FR-AI.2）：多轮流式、可取消/重试；本批会话仅内存态（M5-D 落盘）。
@MainActor
final class AIChatStore: ObservableObject {
  struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: AIChatMessage.Role
    var content: String
    var isStreaming = false
    /// 用户点停止后保留的部分回复标记
    var wasCancelled = false
    /// 该轮实际附带的上下文摘要（user 消息行小字）
    var contextSummary: String?
    /// 送模型的完整 user 消息（含上下文标签块）；重试时复用当轮问题重新采集，历史轮送此原始问题
    var promptQuestion: String?
  }

  enum Phase: Equatable {
    case idle
    case streaming
    case failed(String)
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

  private let settings: AISettingsStore
  private let service: AIService
  private var streamTask: Task<Void, Never>?
  /// 流式增量缓冲（节流落 @Published，防每秒几十次全面板重渲）
  private var streamBuffer = ""
  private var flushScheduled = false

  // 会话按文档隔离（FR-AI.3 v1.2）：key = 文档相对工作区路径（"" = 工作区通用线程）
  private var threads: [String: [ChatMessage]] = [:]
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
    workspaceRoot = newRoot
    storageBroken = false
    threads = [:]
    messages = []
    phase = .idle
    guard let newRoot else { return }
    do {
      for session in try AISessionStore.load(workspaceRoot: newRoot) {
        threads[session.docPath ?? ""] = session.messages.map(ChatMessage.init(stored:))
      }
    } catch {
      storageBroken = true
      storageError = error.localizedDescription
      Logger.ai.error("AI 会话载入失败: \(String(describing: error), privacy: .public)")
    }
    messages = threads[activeDocKey] ?? []
  }

  /// 激活文档变化：切换会话线程（同 key 幂等；流式途中切换取消在途——语境已变）
  func bindDocument(_ url: URL?) {
    let key = docKey(for: url)
    guard key != activeDocKey else { return }
    if phase == .streaming { cancel() }
    threads[activeDocKey] = messages
    activeDocKey = key
    activeDocName = url?.lastPathComponent
    messages = threads[key] ?? []
    phase = .idle
  }

  /// 退出/切工作区前立即落盘
  func flush() {
    persistDebouncer.cancel()
    persistNow()
  }

  private func docKey(for url: URL?) -> String {
    guard let url else { return "" }
    let path = url.standardizedFileURL.path
    if let rootPath = workspaceRoot?.path, path.hasPrefix(rootPath + "/") {
      return String(path.dropFirst(rootPath.count + 1))
    }
    return path
  }

  /// 消息变化统一收口：回写线程表 + 防抖落盘
  private func syncActiveThread() {
    threads[activeDocKey] = messages
    guard isPersistent else { return }
    persistDebouncer.schedule { [weak self] in
      self?.persistNow()
    }
  }

  private func persistNow() {
    guard let workspaceRoot, isPersistent else { return }
    threads[activeDocKey] = messages
    let sessions = threads.compactMap { key, thread -> AISessionStore.StoredSession? in
      guard !thread.isEmpty else { return nil }
      return AISessionStore.StoredSession(
        docPath: key.isEmpty ? nil : key,
        messages: thread.map(\.stored),
        updatedAt: Date()
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
    dispatch(question: trimmed, selection: selection)
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
    syncActiveThread()
  }

  // MARK: - 私有

  /// 采集三层上下文（选区/当前文档/工作区检索，按设置开关）并发起流式请求。
  /// md 选区经桥异步（超时回 nil 不阻塞）；文档超预算走结构选节两遍路由（v1.2）
  private func dispatch(question: String, selection: AISettingsStore.ResolvedModel) {
    streamTask = Task { [weak self] in
      await self?.prepareAndStream(question: question, resolved: selection)
    }
  }

  private func prepareAndStream(question: String, resolved: AISettingsStore.ResolvedModel) async {
    let includeSelection = settings.settings.contextIncludeSelection
    let includeDocument = settings.settings.contextIncludeDocument
    let includeWorkspace = settings.settings.contextIncludeWorkspace
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

    // ② 工作区检索（第三层，v1.2 完整形态）：召回文件切节 → 候选少直接全注入
    //（省一遍调用），多则 LLM 目录选节，路由失败回退片段
    var hits: [AIContextBuilder.WorkspaceHit] = []
    if includeWorkspace {
      let candidates = await withCheckedContinuation { continuation in
        contextSources.workspaceCandidates(question) { continuation.resume(returning: $0) }
      }
      guard !Task.isCancelled else { return }
      if candidates.count <= AIWorkspaceRetriever.directInjectThreshold {
        hits = AIWorkspaceRetriever.assembleHits(candidates: candidates, picked: Array(candidates.indices))
      } else if let picked = await routeWorkspace(question: question, candidates: candidates, resolved: resolved) {
        hits = AIWorkspaceRetriever.assembleHits(candidates: candidates, picked: picked)
      } else {
        hits = AIWorkspaceRetriever.fallbackHits(candidates: candidates)
      }
    }
    guard !Task.isCancelled else { return }

    // ③ 当前文档：预算内整文；超预算且可切节 → 两遍路由（失败回退头部截断）
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
      documentAnnotation: annotation,
      workspaceHits: hits
    )
    startStreaming(question: question, built: built, resolved: resolved, maxTokens: replyTokens)
  }

  /// 工作区候选选节（第三层的路由第一遍）；失败返回 nil（调用方回退片段注入）
  private func routeWorkspace(
    question: String,
    candidates: [AIWorkspaceRetriever.Candidate],
    resolved: AISettingsStore.ResolvedModel
  ) async -> [Int]? {
    do {
      let reply = try await service.complete(
        kind: resolved.kind,
        config: resolved.config,
        model: resolved.model,
        messages: AISectionRouter.routingMessages(
          question: question,
          outline: AIWorkspaceRetriever.routingOutline(candidates)
        ),
        maxTokens: AISectionRouter.maxTokens
      )
      let picked = AISectionRouter.parsePicked(reply, sectionCount: candidates.count)
      Logger.ai.debug("工作区路由选节: \(picked?.count ?? 0) 节 / 候选 \(candidates.count) 节")
      return picked
    } catch {
      Logger.ai.error("工作区路由失败，回退片段: \((error as? AIServiceError)?.logSafeDescription ?? "未知错误", privacy: .public)")
      return nil
    }
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

  private func startStreaming(question: String, built: AIContextBuilder.BuiltContext, resolved: AISettingsStore.ResolvedModel, maxTokens: Int) {
    var userRow = ChatMessage(role: .user, content: question)
    userRow.contextSummary = built.summary
    userRow.promptQuestion = question
    messages.append(userRow)
    var assistantRow = ChatMessage(role: .assistant, content: "")
    assistantRow.isStreaming = true
    messages.append(assistantRow)
    syncActiveThread()

    // 历史轮：user 送原始问题（不重复带全文），仅当轮带上下文；空 assistant 已由 trimHistory 丢弃
    var outgoing: [AIChatMessage] = [.system(AIContextBuilder.systemPrompt())]
    let history = messages.dropLast(2).map { message in
      AIChatMessage(role: message.role, content: message.role == .user ? (message.promptQuestion ?? message.content) : message.content)
    }
    outgoing += AIContextBuilder.trimHistory(Array(history))
    outgoing.append(.user(built.userMessage))

    streamBuffer = ""
    streamTask = Task { [weak self] in
      guard let self else { return }
      do {
        let stream = self.service.stream(
          kind: resolved.kind,
          config: resolved.config,
          model: resolved.model,
          messages: outgoing,
          maxTokens: maxTokens
        )
        for try await event in stream {
          switch event {
          case .text(let delta):
            self.streamBuffer += delta
            self.scheduleFlush()
          case .toolCalls:
            // agent 循环于 v1.3④ 消费；此前不带 tools 参数不会出现
            break
          }
        }
        guard !Task.isCancelled else { return }
        self.finalizeStreaming(cancelled: false)
        self.phase = .idle
      } catch is CancellationError {
        // cancel() 已收尾
      } catch {
        guard !Task.isCancelled else { return }
        self.flushNow()
        self.finalizeStreaming(cancelled: false)
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let safe = (error as? AIServiceError)?.logSafeDescription ?? "未知错误"
        Logger.ai.error("AI 对话失败: \(safe, privacy: .public)")
        self.phase = .failed(description)
      }
      self.streamTask = nil
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
    if cancelled, messages[last].content.isEmpty {
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
  }

  var stored: AISessionStore.StoredMessage {
    AISessionStore.StoredMessage(
      role: role.rawValue,
      content: content,
      contextSummary: contextSummary,
      promptQuestion: promptQuestion,
      wasCancelled: wasCancelled ? true : nil
    )
  }
}
