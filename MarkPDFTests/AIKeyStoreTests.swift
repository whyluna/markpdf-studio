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

  @MainActor
  func testInitRebuildsCustomProviderAccount() {
    let storage = InMemoryAIKeyStorage()
    storage.set("sk-custom", for: "custom-abc123")
    let store = AIKeyStore(storage: storage)
    XCTAssertTrue(
      store.configuredAccounts.contains("custom-abc123"),
      "动态自定义 Provider ID 必须在重启后恢复为已配置")
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

/// 钥匙串自愈修复回归（2026-08-19 现场：重签名后旧条目 ACL 拒绝，
/// 「显示已配置、请求报未配置、重存无效」）
final class AIKeychainHealTests: XCTestCase {
  /// 真实钥匙串上的增改删回路（一次性随机 service，不碰用户条目；
  /// 同一二进制内无 ACL 问题，验证的是代码管道完整性）
  func testKeychainRoundTripWithInjectableService() {
    let service = "com.whyluna.markpdf.ai.test-\(UUID().uuidString)"
    defer { _ = KeychainAIKeyStorage(service: service).set(nil, for: "scratch") }
    let storage = KeychainAIKeyStorage(service: service)

    XCTAssertFalse(storage.exists(for: "scratch"))
    XCTAssertTrue(storage.set("sk-first", for: "scratch"))
    XCTAssertTrue(storage.exists(for: "scratch"), "查属性不弹授权（启动检查通道）")
    XCTAssertEqual(storage.string(for: "scratch"), "sk-first")

    XCTAssertTrue(storage.set("sk-second", for: "scratch"), "更新路径")
    XCTAssertEqual(storage.string(for: "scratch"), "sk-second")

    XCTAssertTrue(storage.set(nil, for: "scratch"), "删除路径")
    XCTAssertNil(storage.string(for: "scratch"))
    XCTAssertFalse(storage.exists(for: "scratch"))
  }

  /// 写成功但读不回（旧条目 ACL 拒绝的形态）：save 必须失败并清理，
  /// 不得把 account 标成已配置（矛盾态根因）
  @MainActor
  func testSaveDetectsUnreadableWriteAndCleansUp() {
    final class WriteOnlyKeyStorage: AIKeyStorage {
      private var map: [String: String] = [:]
      var deletions: [String] = []
      func string(for account: String) -> String? { nil }
      func exists(for account: String) -> Bool { map[account] != nil }
      func set(_ value: String?, for account: String) -> Bool {
        if let value, !value.isEmpty {
          map[account] = value
        } else {
          map.removeValue(forKey: account)
          deletions.append(account)
        }
        return true
      }
    }
    let storage = WriteOnlyKeyStorage()
    let store = AIKeyStore(storage: storage)

    XCTAssertFalse(store.save("sk-abc", for: "kimi"), "读不回 = 保存失败")
    XCTAssertNotNil(store.lastError, "失败必须可感知（NFR-5）")
    XCTAssertFalse(store.configuredAccounts.contains("kimi"), "不得标成已配置")
    XCTAssertEqual(storage.deletions, ["kimi"], "不可用条目立即清理")
  }
}

/// 容器文件 + 混合存储（2026-08-19 钥匙串弹窗根治）：文件为主、钥匙串只读兼容
final class AIKeyFileStorageTests: XCTestCase {
  private var dir: URL!

  override func setUp() {
    super.setUp()
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIKeyFile-\(UUID().uuidString)")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: dir)
    super.tearDown()
  }

  private func makeFile() -> ContainerFileKeyStorage {
    ContainerFileKeyStorage(directory: dir)
  }

  func testFileRoundTripAndPermissions() throws {
    let storage = makeFile()
    XCTAssertTrue(storage.set("sk-file-1", for: "kimi"))
    XCTAssertEqual(storage.string(for: "kimi"), "sk-file-1")
    XCTAssertTrue(storage.exists(for: "kimi"))

    XCTAssertTrue(storage.set("sk-file-2", for: "kimi"), "覆盖更新")
    XCTAssertEqual(storage.string(for: "kimi"), "sk-file-2")

    storage.set(nil, for: "kimi")
    XCTAssertNil(storage.string(for: "kimi"))
    XCTAssertFalse(storage.exists(for: "kimi"))

    // 重开实例（模拟重启）仍在
    XCTAssertTrue(storage.set("sk-persist", for: "openai"))
    XCTAssertEqual(makeFile().string(for: "openai"), "sk-persist")
    // 0600 权限
    let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("api-keys.json").path)
    XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600)
  }

  func testHybridReadsFileFirstThenKeychain() {
    final class FakeKeychain: AIKeyStorage {
      var map: [String: String] = [:]
      var deletes: [String] = []
      var reads: [String] = []
      func string(for account: String) -> String? { reads.append(account); return map[account] }
      func exists(for account: String) -> Bool { map[account] != nil }
      func set(_ value: String?, for account: String) -> Bool {
        if let value, !value.isEmpty { map[account] = value } else { map.removeValue(forKey: account); deletes.append(account) }
        return true
      }
    }
    let keychain = FakeKeychain()
    keychain.map = ["kimi": "sk-legacy"]
    let hybrid = HybridAIKeyStorage(file: ContainerFileKeyStorage(directory: dir), keychain: keychain)
    // 文件里没有 → 回落钥匙串（旧值兼容）
    XCTAssertEqual(hybrid.string(for: "kimi"), "sk-legacy")
    XCTAssertTrue(hybrid.exists(for: "kimi"))

    // 保存新 Key：写文件 + 清钥匙串旧条目（此后不再回落、不再弹授权）
    XCTAssertTrue(hybrid.set("sk-new", for: "kimi"))
    XCTAssertEqual(hybrid.string(for: "kimi"), "sk-new")
    XCTAssertNil(keychain.map["kimi"])
  }
}
