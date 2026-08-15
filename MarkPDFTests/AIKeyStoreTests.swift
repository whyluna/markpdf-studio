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
  func testSaveTrimsWhitespaceAndNewlines() {
    let store = AIKeyStore(storage: InMemoryAIKeyStorage())
    // 粘贴自网页的 key 常带尾换行/空格：含 \n 的头值会被 CFNetwork 静默丢弃（全线 401）
    store.save("  sk-abc123\n", for: "openai")
    XCTAssertEqual(store.apiKey(for: "openai"), "sk-abc123")
    XCTAssertTrue(store.configuredAccounts.contains("openai"))
    // 清洗后为空等同删除
    store.save(" \n ", for: "openai")
    XCTAssertNil(store.apiKey(for: "openai"))
    XCTAssertFalse(store.configuredAccounts.contains("openai"))
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

  /// 钥匙串写入失败（锁屏等）：不得把 account 标成「已配置」，且须上报错误（NFR-5）
  @MainActor
  func testFailedSaveNotMarkedConfigured() {
    let store = AIKeyStore(storage: FailingAIKeyStorage())
    let ok = store.save("sk-1", for: "deepseek")
    XCTAssertFalse(ok)
    XCTAssertFalse(store.configuredAccounts.contains("deepseek"), "写入失败不得显示已配置")
    XCTAssertNotNil(store.lastError, "失败须用户可感知")
  }
}
