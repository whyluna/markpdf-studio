import XCTest
@testable import MarkPDF

/// 划词翻译状态机（FR-AI.1）：AI 引擎路径全覆盖；系统引擎的 TranslationSession
/// 只能由视图层取得，不在单测范围。
final class TranslationStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "TranslationStoreTests"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    super.tearDown()
  }

  @MainActor
  private func makeStore(
    transport: AITransport,
    withKey: Bool = true,
    configure: (AISettingsStore) -> Void = { _ in }
  ) -> TranslationStore {
    let settings = AISettingsStore(defaults: defaults)
    settings.update { $0.translationEngine = .ai }
    settings.updateConfig(.deepseek) { $0.isEnabled = true }
    configure(settings)
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    if withKey {
      keys.save("sk-test", for: AIProviderKind.deepseek.rawValue)
    }
    return TranslationStore(settings: settings, service: AIService(transport: transport, keys: keys))
  }

  @MainActor
  private func httpResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  @MainActor
  func testAISuccess() async {
    let transport = AIServiceTests.MockAITransport { _ in
      (Data(#"{"choices":[{"message":{"content":" 你好，世界 "}}]}"#.utf8), self.httpResponse(200))
    }
    let store = makeStore(transport: transport)
    store.translate("Hello, world")
    // translate 内 AI 路径是 Task 异步，等待相位落定
    await Task.yield()
    try? await Task.sleep(nanoseconds: 100_000_000)
    guard case .success(let translated) = store.phase else {
      return XCTFail("期望 success，实际 \(store.phase)")
    }
    XCTAssertEqual(translated, "你好，世界")
    XCTAssertEqual(store.engineTitle, AIProviderKind.deepseek.title)
  }

  @MainActor
  func testAIFailsWithoutEnabledProvider() {
    let transport = AIServiceTests.MockAITransport()
    let store = makeStore(transport: transport) { settings in
      settings.updateConfig(.deepseek) { $0.isEnabled = false }
    }
    store.translate("Hello")
    guard case .failure(let message) = store.phase else {
      return XCTFail("期望 failure，实际 \(store.phase)")
    }
    XCTAssertTrue(message.contains("设置"))
  }

  @MainActor
  func testAIFailsWithoutAPIKey() async {
    let transport = AIServiceTests.MockAITransport()
    let store = makeStore(transport: transport, withKey: false)
    store.translate("Hello")
    try? await Task.sleep(nanoseconds: 100_000_000)
    guard case .failure = store.phase else {
      return XCTFail("期望 failure，实际 \(store.phase)")
    }
  }

  @MainActor
  func testSameLanguageNeedsNoTranslation() {
    let transport = AIServiceTests.MockAITransport()
    let store = makeStore(transport: transport) { settings in
      settings.update { $0.targetLanguage = .zh }
    }
    store.translate("这是一段中文文本，目标语言也是中文。")
    guard case .success(let result) = store.phase else {
      return XCTFail("期望 success，实际 \(store.phase)")
    }
    XCTAssertEqual(result, "这是一段中文文本，目标语言也是中文。")
    XCTAssertEqual(store.engineTitle, "无需翻译")
  }

  @MainActor
  func testPresentFailure() {
    let transport = AIServiceTests.MockAITransport()
    let store = makeStore(transport: transport)
    store.presentFailure("已取消", for: "Hello")
    XCTAssertEqual(store.phase, .failure("已取消"))
    XCTAssertEqual(store.sourceText, "Hello")
  }

  @MainActor
  func testResetClearsState() {
    let transport = AIServiceTests.MockAITransport()
    let store = makeStore(transport: transport)
    store.presentFailure("x", for: "y")
    store.reset()
    XCTAssertEqual(store.phase, .hidden)
    XCTAssertEqual(store.sourceText, "")
    XCTAssertNil(store.systemConfiguration)
  }

  @MainActor
  func testBlankTextIgnored() {
    let transport = AIServiceTests.MockAITransport()
    let store = makeStore(transport: transport)
    store.translate("   \n  ")
    XCTAssertEqual(store.phase, .hidden)
  }
}
