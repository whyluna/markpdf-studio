import XCTest
@testable import MarkPDF

/// API Key 存储（FR-AI.4）：内存实现验证门面行为；Keychain 本体经真机验收
final class AIKeyStoreTests: XCTestCase {
  @MainActor
  func testSaveReadDelete() {
    let store = AIKeyStore(storage: InMemoryAIKeyStorage())
    XCTAssertNil(store.apiKey(for: "deepseek"))
    XCTAssertFalse(store.configuredAccounts.contains("deepseek"))

    store.save("sk-1", for: "deepseek")
    XCTAssertEqual(store.apiKey(for: "deepseek"), "sk-1")
    XCTAssertTrue(store.configuredAccounts.contains("deepseek"))

    store.remove(for: "deepseek")
    XCTAssertNil(store.apiKey(for: "deepseek"))
    XCTAssertFalse(store.configuredAccounts.contains("deepseek"))
  }

  @MainActor
  func testOverwrite() {
    let store = AIKeyStore(storage: InMemoryAIKeyStorage())
    store.save("sk-1", for: "openai")
    store.save("sk-2", for: "openai")
    XCTAssertEqual(store.apiKey(for: "openai"), "sk-2")
  }

  @MainActor
  func testAccountsAreIsolated() {
    let store = AIKeyStore(storage: InMemoryAIKeyStorage())
    store.save("sk-a", for: "openai")
    store.save("sk-b", for: "anthropic")
    XCTAssertEqual(store.apiKey(for: "openai"), "sk-a")
    XCTAssertEqual(store.apiKey(for: "anthropic"), "sk-b")
    store.remove(for: "openai")
    XCTAssertEqual(store.apiKey(for: "anthropic"), "sk-b")
  }

  /// 空串视为删除（防止保存占位空 Key 后误以为已配置）
  @MainActor
  func testEmptyStringTreatedAsDelete() {
    let store = AIKeyStore(storage: InMemoryAIKeyStorage())
    store.save("sk-1", for: "kimi")
    store.save("", for: "kimi")
    XCTAssertNil(store.apiKey(for: "kimi"))
  }

  /// init 时扫描既有 Key 重建「已配置」集合
  @MainActor
  func testInitRebuildsConfiguredAccounts() {
    let storage = InMemoryAIKeyStorage()
    storage.set("sk-x", for: AIProviderKind.qwen.rawValue)
    let store = AIKeyStore(storage: storage)
    XCTAssertTrue(store.configuredAccounts.contains(AIProviderKind.qwen.rawValue))
  }
}
