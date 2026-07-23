import XCTest
@testable import MarkPDF

/// AI 偏好持久化（FR-AI.4）：默认值、读写回环、损坏回退、Provider 解析
final class AISettingsStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "AISettingsStoreTests"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    super.tearDown()
  }

  @MainActor
  func testDefaults() {
    let store = AISettingsStore(defaults: defaults)
    XCTAssertEqual(store.settings.translationEngine, .system)
    XCTAssertEqual(store.settings.targetLanguage, .auto)
    XCTAssertTrue(store.settings.autoTranslateOnSelection)
    XCTAssertTrue(store.settings.contextIncludeSelection)
    XCTAssertTrue(store.settings.contextIncludeDocument)
    XCTAssertFalse(store.settings.contextIncludeWorkspace)
    XCTAssertFalse(store.privacyNoticeAcknowledged)
    XCTAssertNil(store.chatProviderKind)
  }

  @MainActor
  func testPersistAcrossInstances() {
    let store = AISettingsStore(defaults: defaults)
    store.updateConfig(.deepseek) {
      $0.isEnabled = true
      $0.model = "deepseek-reasoner"
    }
    store.update {
      $0.translationEngine = .ai
      $0.targetLanguage = .zh
      $0.contextIncludeWorkspace = true
      $0.chatProvider = AIProviderKind.deepseek.rawValue
    }

    let reopened = AISettingsStore(defaults: defaults)
    XCTAssertEqual(reopened.config(for: .deepseek).model, "deepseek-reasoner")
    XCTAssertTrue(reopened.config(for: .deepseek).isEnabled)
    XCTAssertEqual(reopened.settings.translationEngine, .ai)
    XCTAssertEqual(reopened.settings.targetLanguage, .zh)
    XCTAssertTrue(reopened.settings.contextIncludeWorkspace)
    XCTAssertEqual(reopened.chatProviderKind, .deepseek)
    XCTAssertEqual(reopened.translationProviderKind, .deepseek)
  }

  @MainActor
  func testCorruptJSONFallsBackToDefault() {
    defaults.set(Data("not json".utf8), forKey: "settings.ai.v1")
    let store = AISettingsStore(defaults: defaults)
    XCTAssertEqual(store.settings, AISettings())
  }

  @MainActor
  func testChatProviderResolution() {
    let store = AISettingsStore(defaults: defaults)
    // 显式选择但未启用 → 回落到第一个已启用的
    store.updateConfig(.openai) { $0.isEnabled = true }
    store.update { $0.chatProvider = AIProviderKind.deepseek.rawValue }
    XCTAssertEqual(store.chatProviderKind, .openai)
    // 启用显式选择后命中
    store.updateConfig(.deepseek) { $0.isEnabled = true }
    XCTAssertEqual(store.chatProviderKind, .deepseek)
  }

  /// 未存配置时读取返回预设默认（开关默认关、URL/模型为内置值）
  @MainActor
  func testConfigFallsBackToPreset() {
    let store = AISettingsStore(defaults: defaults)
    let config = store.config(for: .kimi)
    XCTAssertFalse(config.isEnabled)
    XCTAssertEqual(config.baseURL, AIProviderKind.kimi.defaultBaseURL)
    XCTAssertEqual(config.model, AIProviderKind.kimi.defaultModel)
  }
}
