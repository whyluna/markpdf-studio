import Combine
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
    /// 本轮写提案封存后的变更集 ID（FR-AI.5；渲染变更卡片；不持久化，重启即失效）
    var changeSetID: UUID?
    /// 写作模式下本轮以普通回答收尾、未产生任何提案（防模型口头幻觉「已提交」，
    /// 渲染为消息下方警示行）
    var writingNoProposal = false
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
    /// 最后真实修改时间（仅消息变化时刷新；合并排序与落盘 updatedAt 用——
    /// 此前 persistNow 每次全量刷 Date()，双键同批写出让「按时间合并」退化为随机序）
    var updatedAt = Date.distantPast
  }

  @Published private(set) var messages: [ChatMessage] = []
  @Published private(set) var phase: Phase = .idle
  /// 当前线程归属（面板头显示：文档名 / nil = 工作区通用）
  @Published private(set) var activeDocName: String?
  /// 会话文件损坏提示（FR-AI.3 不静默吞；损坏期间禁写回防覆盖）
  @Published var storageError: String?
  /// 当前线程是否持久（v1.5：会话跟文件走，唯一不持久的是无工作区窗口的通用线程）
  var isPersistent: Bool { !activeDocKey.isEmpty && !(repository?.isBroken ?? false) }

  /// 面板头部徽标（Provider · 模型）；无可用 Provider 为空串
  var providerBadge: String {
    guard let selection = settings.chatSelection else { return "" }
    return "\(selection.provider.title) · \(selection.model)"
  }

  var contextSources = AIContextSources()
  /// AI 写作模式（2026-08-19 用户决策）：面板头部开关，开 = 用户意图是写文件，
  /// 模型带写工具与写作纪律；关 = 纯问答（写工具一律不下发）。每次启动默认关
  @Published var isWritingMode = false
  /// 写提案审查状态机（FR-AI.5）：循环内收提案、循环结束封存挂卡片、应用/撤销
  let changeStore = AIChangeStore()
  /// 打开中文件的实时文本（写工具校验以编辑器内存为准；WindowSession 接线）
  var liveTextProvider: ((URL) -> String?)?

  /// agent 循环轮数上限（超限后最后一轮不带 tools，模型只能作答）
  static let maxToolTurns = 6
  /// 单轮工具结果总量上限（字符）
  static let toolResultsBudgetPerTurn = 12_000

  private let settings: AISettingsStore
  private let service: AIService
  /// changeStore 是 let 属性：自身 @Published 变化不会触发本类视图刷新——
  /// 转发其 objectWillChange（否则变更卡片应用/拒绝后停在旧状态，实测「点多次才生效」）
  private var changeStoreCancellable: AnyCancellable?
  /// 每线程独立的 agent 运行注册表（2026-08-19 用户需求：多文档并行问答/写作，
  /// 切文档只切显示不取消在途运行）。phase 始终反映「激活线程」的状态
  private var runs: [String: Task<Void, Never>] = [:]
  /// 每线程的流式增量缓冲（节流落 @Published，防每秒几十次全面板重渲）；
  /// cancel()/workspaceDidChange 需在运行外冲刷残余，故挂在实例上按线程隔离
  private var runBuffers: [String: (buffer: String, flushScheduled: Bool)] = [:]
  /// 每线程失败信息（面板按激活线程显示对应失败行）
  private var threadFailures: [String: String] = [:]
  /// 后台压缩任务（历史超预算时旧轮次并入滚动摘要；不阻塞当轮）
  private var compactionTask: Task<Void, Never>?
  /// 压缩任务身份令牌：旧任务的 defer 只在仍是当前任务时才清手柄，
  /// 防「取消旧任务 → 新任务已启动 → 旧 defer 误清新手柄」
  private var activeCompactionID: UUID?
  /// 压缩失败后间隔一轮再试
  private var skipCompactionOnce = false

  // 会话按文档隔离（FR-AI.3）：key = 文档绝对路径（解析符号链接）；
  // 工作区通用线程 = 工作区根绝对路径；无工作区窗口的通用线程 = 空串（内存态）。
  // v1.5 起线程集中存全局仓库（AISessionRepository），不再按工作区分文件——
  // 会话是文件的属性，同一文件经不同工作区层级打开时不再分叉
  private var threads: [String: Thread] = [:]
  private var activeDocKey = ""
  private var workspaceRoot: URL?
  private let persistDebouncer = Debouncer(interval: 0.5)
  /// 全局会话仓库（磁盘唯一写者；App 级单实例，多窗口共享）
  private weak var repository: AISessionRepository?

  init(settings: AISettingsStore, service: AIService, repository: AISessionRepository? = nil) {
    self.settings = settings
    self.service = service
    self.repository = repository
    changeStoreCancellable = changeStore.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  // MARK: - 工作区 / 文档线程（FR-AI.3）

  /// 工作区变化：迁移旧版工作区存储 → 切换通用线程归属。
  /// 线程跟文件走（TextMate 范式）：会话按文件绝对路径存全局仓库，
  /// 同一文件无论从哪个工作区层级或外部打开都是同一条线程
  func workspaceDidChange(root: URL?) {
    let newRoot = root?.standardizedFileURL
    guard newRoot?.path != workspaceRoot?.path else { return }
    // 工作区已换：所有在途运行取消并收尾（上下文语境整体失效）
    for (_, task) in runs { task.cancel() }
    let cancelledKeys = Array(runs.keys)
    runs.removeAll()
    for key in cancelledKeys {
      finalizeStreaming(cancelled: true, key: key)
      runBuffers.removeValue(forKey: key)
    }
    // 工作区已换：未审查的写提案一律作废（路径按旧根解析，应用到新根会开出意外文件）
    changeStore.rejectPendingSets()
    compactionTask?.cancel()
    compactionTask = nil
    activeCompactionID = nil
    flush()
    workspaceRoot = newRoot
    if let newRoot, let repository {
      repository.migrateWorkspaceStoreIfNeeded(root: newRoot)
      storageError = repository.storageError
      // 迁移可能为已激活的线程带入历史（启动时序：标签恢复先绑文档、工作区后载入）——
      // 丢弃空的缓存线程让其重新读仓库，否则激活线程停在空态并把仓库记录覆盖成空（实锤丢数据）
      threads = threads.filter { !$0.value.messages.isEmpty }
      if messages.isEmpty {
        messages = loadThread(activeDocKey).messages
      }
    }
    // 通用线程键随工作区变化（无工作区时为空串——内存态不持久）
    if activeDocName == nil {
      activeDocKey = Self.workspaceThreadKey(for: newRoot)
      messages = loadThread(activeDocKey).messages
      phase = .idle
    }
  }

  /// 激活文档变化：只切换面板显示的线程——在途运行继续跑在原线程
  ///（2026-08-19 用户决策：切文档不取消，多文档可来回并行提问/写作）
  func bindDocument(_ url: URL?) {
    let key = url.map(Self.threadKey) ?? Self.workspaceThreadKey(for: workspaceRoot)
    guard key != activeDocKey else {
      activeDocName = url?.lastPathComponent
      return
    }
    storeActiveThreadMessages()
    activeDocKey = key
    activeDocName = url?.lastPathComponent
    messages = loadThread(key).messages
    refreshPhase()
  }

  /// phase 跟随激活线程：运行中 > 失败 > 空闲
  private func refreshPhase() {
    if runs[activeDocKey] != nil {
      phase = .streaming
    } else if let failure = threadFailures[activeDocKey] {
      phase = .failed(failure)
    } else {
      phase = .idle
    }
  }

  /// 文件/文件夹改名或移动（应用内文件树操作）：会话随路径换键——
  /// 内存线程表、激活线程键、全局仓库一起平移（文件夹后代按前缀）。
  /// 必须先于 tabStore.fileDidMove 调用：换键完成后标签联动触发的
  /// bindDocument(新 URL) 命中同键幂等返回——不会把当前消息回写进旧键
  ///（旧键复活）或把激活线程重载成空
  func rekeySessions(from oldURL: URL, to newURL: URL) {
    let oldKey = Self.threadKey(for: oldURL)
    let newKey = Self.threadKey(for: newURL)
    guard oldKey != newKey else { return }
    func shifted(_ key: String) -> String {
      newKey + key.dropFirst(oldKey.count)
    }
    for key in threads.keys.filter({ $0 == oldKey || $0.hasPrefix(oldKey + "/") }) {
      guard let thread = threads.removeValue(forKey: key) else { continue }
      let target = shifted(key)
      // 目标键已有会话（改名撞上一个有过会话的文件）：必须合并而非覆盖——
      // 否则下一次 persistNow 的盲写会把仓库里刚 merge 好的结果用单侧副本整体覆盖，
      // 目标文件的原有会话从磁盘消失。三处来源都要并入：内存缓存、仓库（本窗未缓存）
      if let existing = threads[target] {
        threads[target] = Self.merged(existing, thread)
      } else if let stored = repository?.session(for: target), !stored.messages.isEmpty {
        let existing = Thread(
          messages: stored.messages.map(ChatMessage.init(stored:)),
          rollingSummary: stored.rollingSummary,
          summarizedCount: stored.summarizedCount ?? 0,
          updatedAt: stored.updatedAt
        )
        threads[target] = Self.merged(existing, thread)
      } else {
        threads[target] = thread
      }
    }
    if activeDocKey == oldKey || activeDocKey.hasPrefix(oldKey + "/") {
      activeDocKey = shifted(activeDocKey)
      activeDocName = URL(fileURLWithPath: activeDocKey).lastPathComponent
      // 激活线程发生合并时同步可见消息：否则下一轮 storeActiveThreadMessages 会用
      // 面板里的单侧消息把内存里的合并结果再覆盖回去
      if let merged = threads[activeDocKey], merged.messages != messages {
        messages = merged.messages
      }
    }
    repository?.rekey(from: oldKey, to: newKey)
  }

  /// 内存线程合并（与 AISessionRepository.merge 同规则）：较旧者消息在前；
  /// 摘要沿用较新一方（下标按旧者消息数平移），较新方无摘要则保留旧摘要
  private static func merged(_ lhs: Thread, _ rhs: Thread) -> Thread {
    let (older, newer) = lhs.updatedAt <= rhs.updatedAt ? (lhs, rhs) : (rhs, lhs)
    var result = Thread(
      messages: older.messages + newer.messages,
      rollingSummary: nil,
      summarizedCount: 0,
      updatedAt: newer.updatedAt
    )
    if let summary = newer.rollingSummary {
      result.rollingSummary = summary
      result.summarizedCount = min(newer.summarizedCount + older.messages.count, result.messages.count)
    } else {
      result.rollingSummary = older.rollingSummary
      result.summarizedCount = older.summarizedCount
    }
    return result
  }

  /// 退出/关窗前立即落盘
  func flush() {
    persistDebouncer.cancel()
    persistNow()
    repository?.flush()
  }

  /// 文件线程键：绝对路径（解析符号链接，同一文件不同路径形态同一条线程）
  nonisolated static func threadKey(for url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// 工作区通用线程键 = 工作区根路径（目录路径与文件路径天然不冲突）；无工作区为空串
  nonisolated static func workspaceThreadKey(for root: URL?) -> String {
    root.map(threadKey) ?? ""
  }

  /// 取线程（内存优先，其次仓库；仓库无记录为空线程）。
  /// 变更卡片随线程恢复（消息引用的变更集按 id 还原，幂等）
  private func loadThread(_ key: String) -> Thread {
    if let thread = threads[key] { return thread }
    guard !key.isEmpty, let stored = repository?.session(for: key) else { return Thread() }
    let thread = Thread(
      messages: stored.messages.map(ChatMessage.init(stored:)),
      rollingSummary: stored.rollingSummary,
      summarizedCount: stored.summarizedCount ?? 0,
      updatedAt: stored.updatedAt
    )
    threads[key] = thread
    changeStore.restoreSets(stored.changes ?? [])
    return thread
  }

  private func storeActiveThreadMessages() {
    var thread = loadThread(activeDocKey)
    // 仅在消息实际变化时刷新修改时间（合并排序依赖真实时间；
    // 切文档/落盘触发的无变化写回不刷——否则同批 Date() 让按时间合并退化为随机序）
    if thread.messages != messages {
      thread.messages = messages
      thread.updatedAt = Date()
    }
    threads[activeDocKey] = thread
  }

  /// 消息变化统一收口：回写线程表 + 防抖落盘
  private func syncActiveThread() {
    storeActiveThreadMessages()
    persistDebouncer.schedule { [weak self] in
      self?.persistNow()
    }
  }

  /// 推送本窗口的线程到全局仓库（仓库合并后整体写出，多窗口互不清空）。
  /// 每线程只存其消息仍引用的变更卡片（防无界膨胀）
  private func persistNow() {
    storeActiveThreadMessages()
    guard let repository else { return }
    for (key, thread) in threads where !key.isEmpty {
      let referencedIDs = Set(thread.messages.compactMap(\.changeSetID))
      repository.update(
        AISessionStore.StoredSession(
          docPath: key,
          messages: thread.messages.map(\.stored),
          updatedAt: thread.updatedAt == .distantPast ? Date() : thread.updatedAt,
          rollingSummary: thread.rollingSummary,
          summarizedCount: thread.summarizedCount,
          changes: changeStore.serializableSets(referencing: referencedIDs)
        ),
        for: key
      )
    }
  }

  // MARK: - 意图

  /// 发送：运行绑定发起线程（切走后继续跑、写回原线程）；同线程已有运行则忽略
  func send(_ question: String) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, runs[activeDocKey] == nil else { return }
    // 首次使用 AI 前隐私告知（手动动作，允许弹窗）
    guard AIPrivacyGate.ensureAcknowledged(store: settings) else { return }
    guard let selection = settings.chatSelection else {
      threadFailures[activeDocKey] = String(localized: "未启用任何 AI Provider，请到 设置 → AI 配置并启用")
      refreshPhase()
      return
    }
    threadFailures[activeDocKey] = nil
    compactIfNeeded(resolved: selection)
    let key = activeDocKey
    phase = .streaming
    runs[key] = Task { [weak self] in
      await self?.prepareAndRun(question: trimmed, resolved: selection, key: key)
    }
  }

  /// 停止激活线程的运行（面板停止按钮只作用于正在看的线程）
  func cancel() {
    let key = activeDocKey
    guard let task = runs[key] else { return }
    task.cancel()
    runs.removeValue(forKey: key)
    finalizeStreaming(cancelled: true, key: key)
    runBuffers.removeValue(forKey: key)
    refreshPhase()
  }

  /// 失败/停止后重发最后一个问题（上下文按重发时现场重新采集，NFR-4「当次选择」）
  func retry() {
    guard runs[activeDocKey] == nil,
      let lastQuestion = messages.last(where: { $0.role == .user })?.promptQuestion
    else { return }
    threadFailures[activeDocKey] = nil
    // 移除失败尾巴：最后一条 user 及其后的所有消息（send 会重新 append）
    if let index = messages.lastIndex(where: { $0.role == .user }) {
      messages.removeSubrange(index...)
      syncActiveThread()
    }
    phase = .idle
    send(lastQuestion)
  }

  func newSession() {
    let key = activeDocKey
    if let task = runs[activeDocKey] {
      task.cancel()
      runs.removeValue(forKey: activeDocKey)
      runBuffers.removeValue(forKey: activeDocKey)
    }
    // 在途压缩一并取消：它的完成回调会把旧滚动摘要写进刚清空的新线程（摘要复活）
    compactionTask?.cancel()
    compactionTask = nil
    activeCompactionID = nil
    // 已调用写工具但尚未走到流收尾的提案属于旧会话；不清会在下一轮 seal 时
    // 冒充新问题的变更卡。只清当前桶，其他并行文档继续运行。
    changeStore.discardPending(bucket: key)
    messages = []
    threadFailures[activeDocKey] = nil
    threads[activeDocKey] = Thread()
    phase = .idle
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
    let compactionID = UUID()
    activeCompactionID = compactionID
    compactionTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.activeCompactionID == compactionID {
          self.compactionTask = nil
          self.activeCompactionID = nil
        }
      }
      do {
        let summary = try await self.service.complete(
          provider: resolved.provider,
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

  private func prepareAndRun(question: String, resolved: AISettingsStore.ResolvedModel, key: String) async {
    let includeSelection = settings.settings.contextIncludeSelection
    let includeDocument = settings.settings.contextIncludeDocument
    // 检索工具随「检索工作区」开关（隐私边界：为回答问题读文件）；
    // 写工具随「AI 写作」面板开关（2026-08-19 重设计：意图开关而非全局配置，
    // 且需开着工作区——没有工作区无处落盘）
    let readToolsEnabled = settings.settings.contextIncludeWorkspace
    // 上下文预算（v1.3）：窗口与回复上限均为用户设定值。
    // 写作模式用独立的更大额度（v2.1 用户决策：工具调用里的文件内容占同一
    // max_tokens，问答 8192 会把大文件提案拦腰截断）
    let workspace = contextSources.workspaceFiles()
    let writeEnabled = isWritingMode && workspace.root != nil
    let tokenSetting = writeEnabled
      ? settings.settings.writingMaxReplyTokens
      : settings.settings.chatMaxReplyTokens
    let replyTokens = AIModelContext.effectiveReplyTokens(
      userSetting: tokenSetting,
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

    // 上轮变更集的审查结果（应用/拒绝/撤销）回传模型——它需知道真实落盘状态
    let outcomeNotes = changeStore.consumeOutcomeNotes(bucket: key)
    let built = AIContextBuilder.buildUserMessage(
      question: question,
      selection: selectionText,
      document: document,
      documentBudget: documentBudget,
      documentAnnotation: annotation,
      changeOutcome: outcomeNotes.isEmpty ? nil : outcomeNotes.joined(separator: "\n")
    )

    // UI 行（写进运行线程；仍是激活线程时镜像到面板）
    mutateThread(key) { thread in
      var userRow = ChatMessage(role: .user, content: question)
      userRow.contextSummary = built.summary
      userRow.promptQuestion = question
      thread.messages.append(userRow)
      var assistantRow = ChatMessage(role: .assistant, content: "")
      assistantRow.isStreaming = true
      thread.messages.append(assistantRow)
    }

    // 组装 outgoing：system(+工具指引) + L2 摘要 + L1 历史原文 + 当轮 user
    let thread = threads[key] ?? Thread()
    var systemPrompt = AIContextBuilder.systemPrompt()
    if readToolsEnabled {
      systemPrompt += "\n\n" + AIWorkspaceTools.systemHint(fileNames: workspace.files.map(\.lastPathComponent))
    }
    if writeEnabled {
      // 写作纪律 + 本应用 Markdown 方言速查（FR-AI.5）
      systemPrompt += "\n\n" + AIToolRegistry.writingHint()
    }
    let historySource = Array(thread.messages.dropLast(2)[min(thread.summarizedCount, max(thread.messages.count - 2, 0))...])
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
      readToolsEnabled: readToolsEnabled,
      writeEnabled: writeEnabled,
      workspaceRoot: workspace.root,
      workspaceFiles: workspace.files,
      key: key
    )
  }

  /// 运行期线程写入统一入口：改线程表（updatedAt 仅实际变化时刷新）；
  /// 目标是激活线程时镜像到面板消息；persist 触发防抖落盘
  private func mutateThread(_ key: String, persist: Bool = true, _ transform: (inout Thread) -> Void) {
    let before = loadThread(key)
    var thread = before
    transform(&thread)
    if thread.messages != before.messages {
      thread.updatedAt = Date()
    }
    threads[key] = thread
    if key == activeDocKey {
      messages = thread.messages
    }
    if persist {
      persistDebouncer.schedule { [weak self] in
        self?.persistNow()
      }
    }
  }

  /// agent 循环：流式作答；模型请求工具 → 执行 → 结果回传 → 下一轮；
  /// 三重终止：模型停止调用 / maxToolTurns 上限（末轮不带 tools）/ 用户取消
  private func runAgentLoop(
    outgoing initial: [AIChatMessage],
    resolved: AISettingsStore.ResolvedModel,
    replyTokens: Int,
    readToolsEnabled: Bool,
    writeEnabled: Bool,
    workspaceRoot: URL?,
    workspaceFiles: [URL],
    key: String
  ) async {
    var outgoing = initial
    var turns = 0
    var totalCalls = 0
    var executedResults: [String: String] = [:]  // name+args → result（重复调用去重）
    var streamedBase = 0  // 本轮开始时 assistant 消息的文本长度（提取当轮新文本）
    // 工具执行上下文（FR-AI.5）：只读工具直接执行；写工具产提案入 changeStore。
    // 写提案按运行分桶入队（并行运行互不串卡），封存只取本运行桶
    let toolContext = AIToolRegistry.Context(
      workspaceRoot: workspaceRoot,
      workspaceFiles: workspaceFiles,
      writeEnabled: writeEnabled,
      enqueueChange: { [weak self] change in self?.changeStore.enqueue(change, bucket: key) },
      liveText: { [weak self] url in self?.liveTextProvider?(url) }
    )

    do {
      while true {
        // 循环顶部先查取消：上一轮最后一个工具返回后才被取消的场景，
        // 不得再发起新一轮 HTTP 请求（取消语义即时，也不白耗配额）
        guard !Task.isCancelled else { return }
        let useTools = (readToolsEnabled || writeEnabled) && turns < Self.maxToolTurns
        var received: [AIToolCall] = []
        if var state = runBuffers[key] { state.buffer = ""; runBuffers[key] = state }
        runBuffers[key] = runBuffers[key] ?? (buffer: "", flushScheduled: false)
        let stream = service.stream(
          provider: resolved.provider,
          config: resolved.config,
          model: resolved.model,
          messages: outgoing,
          maxTokens: replyTokens,
          tools: useTools ? AIToolRegistry.definitions(readEnabled: readToolsEnabled, writeEnabled: writeEnabled) : nil
        )
        for try await event in stream {
          switch event {
          case .text(let delta):
            runBuffers[key]?.0 += delta
            scheduleFlush(key: key)
          case .toolCalls(let calls):
            received = calls
          }
        }
        guard !Task.isCancelled else { return }
        flushNow(key: key)

        if received.isEmpty {
          finalizeStreaming(cancelled: false, key: key)
          finishRun(key: key)
          return
        }

        // 本轮 assistant（文本 + 调用）入 outgoing；UI 挂活动 chips
        let fullText = loadThread(key).messages.last?.content ?? ""
        let turnText = String(fullText.dropFirst(min(streamedBase, fullText.count)))
        streamedBase = fullText.count
        outgoing.append(AIChatMessage(role: .assistant, content: turnText, toolCalls: received))

        var turnBudget = Self.toolResultsBudgetPerTurn
        for (offset, call) in received.enumerated() {
          guard !Task.isCancelled else { return }
          let activityIndex = appendActivity(for: call, key: key)
          let dedupeKey = call.name + call.arguments
          let result: String
          if let previous = executedResults[dedupeKey] {
            result = "Duplicate call (identical arguments). Previous result:\n" + String(previous.prefix(500))
          } else {
            // 注册表路由（FR-AI.5）：只读工具后台执行；写工具校验后提案入队（不落盘）。
            // 内部对取消不传播的后台段同样有补查约定，返回后照旧复查
            result = await AIToolRegistry.execute(call: call, context: toolContext)
            guard !Task.isCancelled else { return }
            executedResults[dedupeKey] = result
          }
          var clipped = String(result.prefix(max(turnBudget, 500)))
          turnBudget = max(turnBudget - clipped.count, 0)
          completeActivity(at: activityIndex, result: clipped, key: key)
          totalCalls += 1
          if offset == received.indices.last {
            // 每轮状态行（PaperQA2 状态注入）：并入最后一个工具结果尾部——预算感知收敛且不破坏消息交替
            clipped += "\n\n[Status] turn \(turns + 1)/\(Self.maxToolTurns) · \(totalCalls) tool calls used · answer directly when you have enough evidence"
          }
          outgoing.append(.toolResult(id: call.id, content: clipped))
        }
        persistDebouncer.schedule { [weak self] in self?.persistNow() }
        turns += 1
        Logger.ai.debug("agent 轮次 \(turns): 执行 \(received.count) 个工具调用")
      }
    } catch is CancellationError {
      // cancel()/workspaceDidChange 已收尾并清理
    } catch {
      guard !Task.isCancelled else { return }
      flushNow(key: key)
      finalizeStreaming(cancelled: false, key: key)
      let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      let safe = (error as? AIServiceError)?.logSafeDescription ?? "未知错误"
      Logger.ai.error("AI 对话失败: \(safe, privacy: .public)")
      threadFailures[key] = description
      finishRun(key: key)
      return
    }
  }

  /// 运行收尾清理（自然结束/失败路径；cancel 路径自行清理）
  private func finishRun(key: String) {
    runs.removeValue(forKey: key)
    runBuffers.removeValue(forKey: key)
    refreshPhase()
  }

  /// 挂载运行中的工具活动 chip（写进运行线程）；返回其在 assistant 消息中的下标
  private func appendActivity(for call: AIToolCall, key: String) -> Int? {
    let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
    let argsSummary = ["query", "path", "section"]
      .compactMap { key in (arguments[key] as? String).map { "\($0)" } }
      .joined(separator: " · ")
    var inserted: Int?
    mutateThread(key, persist: false) { thread in
      guard let last = thread.messages.indices.last,
        thread.messages[last].role == .assistant
      else { return }
      thread.messages[last].toolActivities.append(ToolActivity(name: call.name, argsSummary: argsSummary))
      inserted = thread.messages[last].toolActivities.indices.last
    }
    return inserted
  }

  private func completeActivity(at index: Int?, result: String, key: String) {
    guard let index else { return }
    let summary = String((result.split(separator: "\n").first.map(String.init) ?? "").prefix(80))
    mutateThread(key, persist: false) { thread in
      guard let last = thread.messages.indices.last,
        thread.messages[last].role == .assistant,
        thread.messages[last].toolActivities.indices.contains(index)
      else { return }
      thread.messages[last].toolActivities[index].isRunning = false
      thread.messages[last].toolActivities[index].resultSummary = summary
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
        provider: resolved.provider,
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

  /// 增量节流（~80ms）：缓冲攒批后一次性落最后一条消息（按运行隔离）
  private func scheduleFlush(key: String) {
    guard runBuffers[key]?.flushScheduled != true else { return }
    var state = runBuffers[key] ?? (buffer: "", flushScheduled: false)
    state.flushScheduled = true
    runBuffers[key] = state
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self, var state = self.runBuffers[key] else { return }
      state.flushScheduled = false
      self.runBuffers[key] = state
      self.flushNow(key: key)
    }
  }

  private func flushNow(key: String) {
    guard var state = runBuffers[key], !state.buffer.isEmpty else { return }
    let chunk = state.buffer
    state.buffer = ""
    runBuffers[key] = state
    mutateThread(key, persist: false) { thread in
      guard let last = thread.messages.indices.last,
        thread.messages[last].role == .assistant
      else { return }
      thread.messages[last].content += chunk
    }
  }

  /// 流式收尾（按运行线程）：冲刷缓冲、封存本桶提案挂卡片、落定 assistant；
  /// 零增量的取消消息整体移除（空 assistant 进历史会让 Anthropic 非空校验 400）
  private func finalizeStreaming(cancelled: Bool, key: String) {
    flushNow(key: key)
    // 本轮累积的写提案封存成变更集，挂到最后一条 assistant 消息（卡片渲染，FR-AI.5）。
    // 在守卫之前执行：取消/零文本场景也要留住已产出的提案（用户可审查部分成果）
    let sealedSet = changeStore.sealPending(bucket: key)
    // 写作模式却零提案：模型可能口头声称「已提交修改」而实际没调工具（幻觉）——
    // 显式标记，UI 提示「本轮没有产生任何提案」
    let markNoProposal = sealedSet == nil && isWritingMode && !cancelled
    mutateThread(key) { thread in
      guard let last = thread.messages.indices.last,
        thread.messages[last].role == .assistant
      else { return }
      if let sealedSet {
        thread.messages[last].changeSetID = sealedSet.id
      }
      if markNoProposal {
        thread.messages[last].writingNoProposal = true
      }
      guard thread.messages[last].isStreaming else { return }
      thread.messages[last].isStreaming = false
      thread.messages[last].wasCancelled = cancelled
      // 运行中的活动一并落定（取消场景）
      for index in thread.messages[last].toolActivities.indices {
        thread.messages[last].toolActivities[index].isRunning = false
      }
      if cancelled, thread.messages[last].content.isEmpty,
        thread.messages[last].toolActivities.isEmpty,
        thread.messages[last].changeSetID == nil
      {
        thread.messages.remove(at: last)
      }
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
    changeSetID = stored.changeSetID.flatMap(UUID.init(uuidString:))
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
      },
      changeSetID: changeSetID?.uuidString
    )
  }
}
