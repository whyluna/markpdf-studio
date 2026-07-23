import Foundation
import os
import Translation

/// 划词翻译状态机（FR-AI.1）：双引擎。
/// 系统引擎走 SwiftUI `.translationTask`（TranslationSession 只能由视图层取得），
/// 本 Store 发出 Configuration 请求、视图回调里调 performSystemTranslation 写回结果；
/// AI 引擎走 AIService 非流式补全。
@MainActor
final class TranslationStore: ObservableObject {
  enum Phase: Equatable {
    case hidden
    case translating
    case success(String)
    case failure(String)
  }

  @Published private(set) var phase: Phase = .hidden {
    didSet { Logger.ai.debug("[TR\(self.instanceID)] phase → \(String(describing: self.phase), privacy: .public)") }
  }
  /// 原文（气泡展示 + 重试）
  @Published private(set) var sourceText = ""
  /// 结果来源标注（气泡右上角：系统翻译 / Provider 名）
  @Published private(set) var engineTitle = ""
  /// 系统翻译请求：非 nil 即触发气泡的 .translationTask
  @Published var systemConfiguration: TranslationSession.Configuration?

  /// 实例短 ID（诊断"成功写回与可见气泡是否同一 Store"）
  private let instanceID = String(UUID().uuidString.prefix(4))
  /// 等待系统翻译回调的原文（防止回调时串台）
  private var pendingSystemText: String?
  /// 首次经 `.translationTask` 取得的系统翻译会话：同语言对的后续翻译直接复用，
  /// 绕开「等值 Configuration 赋给 SwiftUI 判无变化、任务不重触发」的坑（永转根因）
  private var systemSession: TranslationSession?
  /// systemSession 对应的语言对（对不上才重新走 Configuration 通道）
  private var systemSessionPair: (source: AITargetLanguage, target: AITargetLanguage)?
  /// 兜底看门狗：系统预检静默失败时（回调永不到达）不让气泡永转
  private var watchdog: Task<Void, Never>?
  private let settings: AISettingsStore
  private let service: AIService

  init(settings: AISettingsStore, service: AIService) {
    self.settings = settings
    self.service = service
    Logger.ai.debug("[TR\(self.instanceID)] store 创建")
  }

  deinit {
    Logger.ai.debug("[TR\(self.instanceID)] store 销毁")
  }

  func reset() {
    phase = .hidden
    sourceText = ""
    engineTitle = ""
    pendingSystemText = nil
    watchdog?.cancel()
    watchdog = nil
    // 不再 invalidate/nil systemConfiguration：session 缓存与配置保留，
    // 下次翻译直接复用 session（本地翻译无成本；在途结果由 pendingSystemText=nil 守卫丢弃）
  }

  /// 控制器侧前置校验未通过的展示（如隐私告知被拒），不经翻译流程
  func presentFailure(_ message: String, for text: String) {
    sourceText = text
    engineTitle = ""
    phase = .failure(message)
  }

  func translate(_ text: String) {
    // PDF 物理行整理成整句（断词相连、换行并空格）：译文质量与排版都受益
    let trimmed = TranslationTextNormalizer.normalize(text)
    guard !trimmed.isEmpty else { return }
    // 同文本翻译途中不重复触发
    if case .translating = phase, sourceText == trimmed { return }
    sourceText = trimmed
    phase = .translating
    armWatchdog(for: trimmed)
    let source = TranslationLanguageResolver.detectSource(trimmed)
    guard let target = TranslationLanguageResolver.resolveTarget(
      source: source,
      setting: settings.settings.targetLanguage
    ) else {
      // 原文已是目标语言
      phase = .success(trimmed)
      engineTitle = "无需翻译"
      return
    }
    switch settings.settings.translationEngine {
    case .system:
      startSystemTranslation(trimmed, source: source, target: target)
    case .ai:
      startAITranslation(trimmed, target: target)
    }
  }

  /// 30 秒无结果即判失败：系统翻译预检可能静默失败（回调永不到达），AI 请求也有挂死可能
  private func armWatchdog(for text: String) {
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard !Task.isCancelled, let self,
        case .translating = self.phase, self.sourceText == text
      else { return }
      Logger.ai.error("翻译超时无响应")
      self.phase = .failure("翻译超时无响应，请重试；系统引擎持续不可用时可改用 AI 大模型引擎")
    }
  }

  // MARK: - 系统翻译

  private func startSystemTranslation(_ text: String, source: AITargetLanguage, target: AITargetLanguage) {
    engineTitle = "系统翻译"
    pendingSystemText = text
    let pair = (source: source, target: target)
    // 同语言对且已有 session：直接复用，不再依赖 .translationTask 重触发（等值配置不重触发=永转）
    if let session = systemSession, let current = systemSessionPair, current == pair {
      Logger.ai.debug("[TR\(self.instanceID)] 复用已取得的系统会话直接翻译")
      Task { await self.performSystemTranslation(using: session) }
      return
    }
    // 首次或语言对变化：弃旧 session，走 Configuration 通道取新 session
    systemSession = nil
    systemSessionPair = pair
    let configuration = TranslationSession.Configuration(
      source: source.localeLanguage,
      target: target.localeLanguage
    )
    if systemConfiguration != nil {
      // 语言对变化：先 invalidate 旧配置（真实变化，任务必重触发）
      Logger.ai.debug("[TR\(self.instanceID)] 语言对变化，invalidate 后赋新配置")
      systemConfiguration?.invalidate()
      systemConfiguration = nil
      DispatchQueue.main.async { [weak self] in
        guard let self, self.pendingSystemText == text else { return }
        self.systemConfiguration = configuration
      }
    } else {
      Logger.ai.debug("[TR\(self.instanceID)] 首次赋配置")
      systemConfiguration = configuration
    }
  }

  /// `.translationTask` 回调（或同语言对复用）里调用：执行系统翻译并写回状态
  func performSystemTranslation(using session: TranslationSession) async {
    // 捕获 session 供同语言对的后续翻译直接复用（pair 在 startSystemTranslation 已记录）
    systemSession = session
    guard let text = pendingSystemText else {
      Logger.ai.debug("[TR\(self.instanceID)] 系统回调到达但无 pending 文本，忽略")
      return
    }
    Logger.ai.debug("[TR\(self.instanceID)] 系统翻译开始: \(text.count) 字")
    do {
      let response = try await session.translate(text)
      guard pendingSystemText == text else {
        Logger.ai.debug("[TR\(self.instanceID)] 系统翻译完成但 pending 已变，丢弃结果")
        return
      }
      phase = .success(response.targetText)
      Logger.ai.debug("[TR\(self.instanceID)] 系统翻译完成: \(text.count) 字 → \(response.targetText.count) 字")
    } catch {
      guard pendingSystemText == text else { return }
      Logger.ai.error("[TR\(self.instanceID)] 系统翻译失败: \(error.localizedDescription, privacy: .public)")
      phase = .failure("系统翻译失败（\(error.localizedDescription)）。可在 设置 → AI 中改用 AI 大模型引擎")
    }
  }

  // MARK: - AI 翻译

  private func startAITranslation(_ text: String, target: AITargetLanguage) {
    guard let kind = settings.translationProviderKind else {
      phase = .failure("未启用任何 AI Provider，请到 设置 → AI 配置并启用")
      return
    }
    engineTitle = kind.title
    let config = settings.config(for: kind)
    let messages = [
      AIChatMessage.system(TranslationPromptBuilder.systemMessage),
      AIChatMessage.user(TranslationPromptBuilder.userPrompt(text: text, target: target)),
    ]
    Task {
      do {
        let translated = try await service.complete(
          kind: kind,
          config: config,
          messages: messages,
          maxTokens: 2048
        )
        guard sourceText == text else { return }
        phase = .success(translated.trimmingCharacters(in: .whitespacesAndNewlines))
      } catch {
        guard sourceText == text else { return }
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Logger.ai.error("AI 翻译失败: \(description, privacy: .public)")
        phase = .failure(description)
      }
    }
  }
}
