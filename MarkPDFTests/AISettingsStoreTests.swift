import XCTest
@testable import MarkPDF

/// AI 偏好持久化（FR-AI.4）：默认值、读写回环、损坏回退、模型级解析与旧版迁移
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
    XCTAssertNil(store.chatSelection)
  }

  @MainActor
  func testPersistAcrossInstances() {
    let store = AISettingsStore(defaults: defaults)
    store.updateConfig(.deepseek) {
      $0.isEnabled = true
      $0.modelSpecs = [AIModelSpec(name: "deepseek-reasoner", contextTokens: 64_000), AIModelSpec(name: "deepseek-chat", contextTokens: 64_000)]
    }
    store.update {
      $0.translationEngine = .ai
      $0.targetLanguage = .zh
      $0.contextIncludeWorkspace = true
      $0.chatModel = AIModelChoice(provider: "deepseek", model: "deepseek-reasoner")
      $0.translationModel = AIModelChoice(provider: "deepseek", model: "deepseek-chat")
    }

    let reopened = AISettingsStore(defaults: defaults)
    XCTAssertEqual(reopened.config(for: .deepseek).models, ["deepseek-reasoner", "deepseek-chat"])
    XCTAssertTrue(reopened.config(for: .deepseek).isEnabled)
    XCTAssertEqual(reopened.settings.translationEngine, .ai)
    XCTAssertEqual(reopened.settings.targetLanguage, .zh)
    XCTAssertTrue(reopened.settings.contextIncludeWorkspace)
    XCTAssertEqual(reopened.chatSelection?.provider.id, AIProviderKind.deepseek.rawValue)
    XCTAssertEqual(reopened.chatSelection?.model, "deepseek-reasoner")
    // 翻译与对话独立选型
    XCTAssertEqual(reopened.translationSelection?.model, "deepseek-chat")
  }

  @MainActor
  func testCorruptJSONFallsBackToDefault() {
    defaults.set(Data("not json".utf8), forKey: "settings.ai.v1")
    let store = AISettingsStore(defaults: defaults)
    XCTAssertEqual(store.settings, AISettings())
  }

  @MainActor
  func testModelResolution() {
    let store = AISettingsStore(defaults: defaults)
    // 显式选择但 Provider 未启用 → 回落到第一个已启用的首模型
    store.updateConfig(.openai) { $0.isEnabled = true }
    store.update { $0.chatModel = AIModelChoice(provider: "deepseek", model: "deepseek-chat") }
    XCTAssertEqual(store.chatSelection?.provider.id, AIProviderKind.openai.rawValue)
    XCTAssertEqual(store.chatSelection?.model, AIProviderKind.openai.defaultModel)
    // 启用显式选择后命中
    store.updateConfig(.deepseek) { $0.isEnabled = true }
    XCTAssertEqual(store.chatSelection?.provider.id, AIProviderKind.deepseek.rawValue)
    XCTAssertEqual(store.chatSelection?.model, "deepseek-chat")
    // 所选模型被从列表删除 → 回落该 Provider 首模型
    store.updateConfig(.deepseek) { $0.modelSpecs = [AIModelSpec(name: "deepseek-reasoner", contextTokens: 64_000)] }
    XCTAssertEqual(store.chatSelection?.model, "deepseek-reasoner")
    // 翻译未单独选择 → 跟随对话模型
    XCTAssertEqual(store.translationSelection, store.chatSelection)
  }

  /// 旧版 JSON（单模型字段 + Provider 粒度选择）迁移：model → models、chatProvider → chatModel
  @MainActor
  func testLegacySingleModelAndProviderChoiceMigration() {
    let legacy = """
      {"providers":{"deepseek":{"isEnabled":true,"baseURL":"https://api.deepseek.com/v1","model":"deepseek-chat"}},
       "chatProvider":"deepseek","translationProvider":"deepseek","translationEngine":"ai"}
      """
    defaults.set(Data(legacy.utf8), forKey: "settings.ai.v1")
    let store = AISettingsStore(defaults: defaults)
    XCTAssertEqual(store.config(for: .deepseek).models, ["deepseek-chat"])
    XCTAssertEqual(store.chatSelection?.provider.id, AIProviderKind.deepseek.rawValue)
    XCTAssertEqual(store.chatSelection?.model, "deepseek-chat")
    XCTAssertEqual(store.translationSelection?.model, "deepseek-chat")
  }

  /// 未存配置时读取返回预设默认（开关默认关、URL/模型为内置值）
  @MainActor
  func testConfigFallsBackToPreset() {
    let store = AISettingsStore(defaults: defaults)
    let config = store.config(for: .kimi)
    XCTAssertFalse(config.isEnabled)
    XCTAssertEqual(config.baseURL, AIProviderKind.kimi.defaultBaseURL)
    XCTAssertEqual(config.models, [AIProviderKind.kimi.defaultModel])
  }
}


/// 自定义 Provider（v2.1 用户需求）：任意添加/配置/删除；解析与请求链统一身份
@MainActor
final class AICustomProviderTests: XCTestCase {
  private var suiteName = "AICustomProviderTests"
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    super.tearDown()
  }

  private func makeStore() -> AISettingsStore {
    AISettingsStore(defaults: defaults)
  }

  func testAddUpdateRemoveCustomProvider() {
    let store = makeStore()
    let added = store.addCustomProvider()
    XCTAssertTrue(added.id.hasPrefix("custom-"))

    store.updateCustomProvider(added.id) {
      $0.name = "我的中转"
      $0.baseURL = "https://relay.example.com/v1"
      $0.modelSpecs = [AIModelSpec(name: "gpt-4o", contextTokens: 128_000)]
    }
    XCTAssertEqual(store.settings.customProviders.first?.name, "我的中转")

    // 持久化往返
    let reloaded = AISettingsStore(defaults: defaults)
    XCTAssertEqual(reloaded.settings.customProviders.count, 1)
    XCTAssertEqual(reloaded.settings.customProviders.first?.baseURL, "https://relay.example.com/v1")

    // 删除：选择引用一并清除
    reloaded.update { $0.chatModel = AIModelChoice(provider: added.id, model: "gpt-4o") }
    reloaded.removeCustomProvider(added.id)
    XCTAssertNil(reloaded.settings.customProviders.first)
    XCTAssertNil(reloaded.settings.chatModel, "选择引用随删除清除")
  }

  func testResolvePicksCustomProviderWhenSelected() {
    let store = makeStore()
    let added = store.addCustomProvider()
    store.updateCustomProvider(added.id) {
      $0.name = "中转"
      $0.baseURL = "https://relay.example.com/v1"
      $0.modelSpecs = [AIModelSpec(name: "m1", contextTokens: 64_000)]
    }
    store.update { $0.chatModel = AIModelChoice(provider: added.id, model: "m1") }

    let selection = store.chatSelection
    XCTAssertEqual(selection?.provider.id, added.id, "自定义 id 命中解析")
    XCTAssertEqual(selection?.provider.family, .openAICompatible)
    XCTAssertEqual(selection?.model, "m1")
    XCTAssertEqual(selection?.contextTokens, 64_000)
    XCTAssertEqual(selection?.config.baseURL, "https://relay.example.com/v1")
  }

  /// 请求链：自定义身份 → 正确 baseURL / 协议族 / 钥匙串账号
  func testRequestBuiltFromCustomIdentity() async throws {
    let store = makeStore()
    let added = store.addCustomProvider()
    store.updateCustomProvider(added.id) {
      $0.baseURL = "https://relay.example.com"
      $0.familyRaw = AIProtocolFamily.anthropic.rawValue
      $0.modelSpecs = [AIModelSpec(name: "claude-x", contextTokens: 200_000)]
    }
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    keys.save("sk-custom", for: added.id)
    let identity = try XCTUnwrap(store.identity(for: added.id))
    XCTAssertEqual(identity.family, .anthropic)

    var captured: URLRequest?
    let transport = AIServiceTests.MockAITransport(sendHandler: { request in
      captured = request
      return (
        Data(#"{"content":[{"type":"text","text":"好"}]}"#.utf8),
        HTTPURLResponse(url: URL(string: "https://relay.example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    })
    let service = AIService(transport: transport, keys: keys)
    let reply = try await service.complete(
      provider: identity, config: store.config(for: identity), model: "claude-x",
      messages: [.user("hi")])
    XCTAssertEqual(reply, "好")
    let request = try XCTUnwrap(captured)
    XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v1/messages", "Anthropic 族路径")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-custom", "Key 按自定义 id 取")
  }
}
