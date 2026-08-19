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
  /// AI 引擎输入超长被截断（气泡注明用；系统翻译端侧处理无需截断）
  @Published private(set) var wasTruncated = false
  /// 系统翻译请求：非 nil 即触发气泡的 .translationTask
  @Published var systemConfiguration: TranslationSession.Configuration?
  /// AI 引擎输入上限（FR-AI.1 口径 2000 字）：长选区译文会超 maxTokens 被静默掐断，先截输入
  static let maxAIInputCharacters = 2000

  /// 实例短 ID（诊断"成功写回与可见气泡是否同一 Store"）
  private let instanceID = String(UUID().uuidString.prefix(4))
  /// 等待系统翻译回调的原文（防止回调时串台）
  private var pendingSystemText: String?
  /// 首次经 `.translationTask` 取得的系统翻译会话：同语言对的后续翻译直接复用，
  /// 绕开「等值 Configuration 赋给 SwiftUI 判无变化、任务不重触发」的坑（永转根因）
  private var systemSession: TranslationSession?
  /// systemSession 对应的语言对（对不上才重新走 Configuration 通道）
  private var systemSessionPair: (source: AITargetLanguage, target: AITargetLanguage)?
  /// 最近一次经 Configuration 通道请求的语言对（Locale 级）。
  /// 语言对切换后旧配置的 `.translationTask` 回调可能迟到——视图把触发时的
  /// Configuration 一并回传，对不上即忽略（否则旧语言对 session 被挂到新语言对
  /// 名下缓存，此后同语言对全走复用，译文语言持续错误）
  private var expectedConfigurationPair: (Locale.Language, Locale.Language)?
  /// 在途翻译的去重键（引擎|源|目标）：同文本同参数重复触发才拦，
  /// 用户改了目标语言/引擎后对同一段文本重试必须放行
  private var inflightTranslationKey: String?
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
    wasTruncated = false
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
    wasTruncated = false
    phase = .failure(message)
  }

  func translate(_ text: String) {
    // PDF 物理行整理成整句（断词相连、换行并空格）：译文质量与排版都受益
    let trimmed = TranslationTextNormalizer.normalize(text)
    guard !trimmed.isEmpty else { return }
    let source = TranslationLanguageResolver.detectSource(trimmed)
    let engine = settings.settings.translationEngine
    guard let target = TranslationLanguageResolver.resolveTarget(
      source: source,
      setting: settings.settings.targetLanguage
    ) else {
      // 原文已是目标语言
      sourceText = trimmed
      wasTruncated = false
      phase = .success(trimmed)
      engineTitle = String(localized: "无需翻译")
      return
    }
    // 同文本同参数翻译途中不重复触发；改了目标语言/引擎后的同文本重试放行
    let translationKey = "\(engine)|\(source)|\(target)"
    if case .translating = phase, sourceText == trimmed, inflightTranslationKey == translationKey { return }
    inflightTranslationKey = translationKey
    sourceText = trimmed
    phase = .translating
    armWatchdog(for: trimmed)
    switch engine {
    case .system:
      // 系统翻译端侧处理，无需截断
      wasTruncated = false
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
      self.phase = .failure(String(localized: "翻译超时无响应，请重试；系统引擎持续不可用时可改用 AI 大模型引擎"))
    }
  }

  // MARK: - 系统翻译

  private func startSystemTranslation(_ text: String, source: AITargetLanguage, target: AITargetLanguage) {
    engineTitle = String(localized: "系统翻译")
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
    expectedConfigurationPair = (source.localeLanguage, target.localeLanguage)
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

  /// `.translationTask` 回调入口（不可信来源）：仅接受与当前请求语言对一致的会话——
  /// 语言对切换后旧配置的回调可能迟到，不校验会把旧语言对 session 挂到新语言对名下
  func performSystemTranslation(using session: TranslationSession, configuration: TranslationSession.Configuration?) async {
    guard let expected = expectedConfigurationPair else {
      Logger.ai.debug("[TR\(self.instanceID)] 非请求期到达的系统会话回调，忽略")
      return
    }
    guard let configuration,
      configuration.source == expected.0,
      configuration.target == expected.1
    else {
      Logger.ai.debug("[TR\(self.instanceID)] 语言对错配的系统会话回调（旧配置迟到），忽略")
      return
    }
    expectedConfigurationPair = nil
    await performSystemTranslation(using: session)
  }

  /// 同语言对复用（可信来源：session 出自本 Store 缓存）与回调校验后共用：执行系统翻译并写回状态
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
      phase = .failure(String(localized: "系统翻译失败（\(error.localizedDescription)）。可在 设置 → AI 中改用 AI 大模型引擎"))
    }
  }

  // MARK: - AI 翻译

  private func startAITranslation(_ text: String, target: AITargetLanguage) {
    guard let selection = settings.translationSelection else {
      phase = .failure(String(localized: "未启用任何 AI Provider，请到 设置 → AI 配置并启用"))
      return
    }
    engineTitle = selection.provider.title
    // AI 引擎输入截断（FR-AI.1 口径 2000 字）：长选区译文会超 maxTokens 被静默掐断，
    // 先截输入并在气泡注明；系统翻译引擎无此处理
    let input = String(text.prefix(Self.maxAIInputCharacters))
    wasTruncated = input.count < text.count
    let messages = [
      AIChatMessage.system(TranslationPromptBuilder.systemMessage),
      AIChatMessage.user(TranslationPromptBuilder.userPrompt(text: input, target: target)),
    ]
    Task {
      do {
        let translated = try await service.complete(
          provider: selection.provider,
          config: selection.config,
          model: selection.model,
          messages: messages,
          maxTokens: 2048
        )
        guard sourceText == text else { return }
        phase = .success(translated.trimmingCharacters(in: .whitespacesAndNewlines))
      } catch {
        guard sourceText == text else { return }
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let safe = (error as? AIServiceError)?.logSafeDescription ?? "未知错误"
        Logger.ai.error("AI 翻译失败: \(safe, privacy: .public)")
        phase = .failure(description)
      }
    }
  }
}
