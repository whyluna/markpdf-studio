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
  /// 当前文档（名字 + 全文）；无激活文档 nil
  var activeDocument: () -> (name: String, text: String)? = { nil }
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

  init(settings: AISettingsStore, service: AIService) {
    self.settings = settings
    self.service = service
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
  }

  // MARK: - 私有

  /// 采集两层上下文（选区/当前文档，按设置开关；工作区检索层 M5-D）并发起流式请求。
  /// md 选区经桥异步，超时回 nil 不阻塞发送
  private func dispatch(question: String, selection: AISettingsStore.ResolvedModel) {
    let includeSelection = settings.settings.contextIncludeSelection
    let includeDocument = settings.settings.contextIncludeDocument
    let document = includeDocument ? contextSources.activeDocument() : nil

    let assemble: (String?) -> Void = { [weak self] selectionText in
      guard let self else { return }
      let built = AIContextBuilder.buildUserMessage(
        question: question,
        selection: includeSelection ? selectionText : nil,
        document: document
      )
      self.startStreaming(question: question, built: built, resolved: selection)
    }
    if !includeSelection {
      assemble(nil)
    } else if contextSources.isPDFActive() {
      assemble(contextSources.pdfSelection())
    } else {
      contextSources.mdSelection { assemble($0) }
    }
  }

  private func startStreaming(question: String, built: AIContextBuilder.BuiltContext, resolved: AISettingsStore.ResolvedModel) {
    var userRow = ChatMessage(role: .user, content: question)
    userRow.contextSummary = built.summary
    userRow.promptQuestion = question
    messages.append(userRow)
    var assistantRow = ChatMessage(role: .assistant, content: "")
    assistantRow.isStreaming = true
    messages.append(assistantRow)

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
          messages: outgoing
        )
        for try await delta in stream {
          self.streamBuffer += delta
          self.scheduleFlush()
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
    guard let last = messages.indices.last, messages[last].role == .assistant, messages[last].isStreaming else { return }
    messages[last].isStreaming = false
    messages[last].wasCancelled = cancelled
    if cancelled, messages[last].content.isEmpty {
      messages.remove(at: last)
    }
  }
}
