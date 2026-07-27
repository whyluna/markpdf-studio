import Foundation
import Security

/// API Key 存储抽象（FR-AI.4）：生产走系统钥匙串，测试走内存
protocol AIKeyStorage {
  func string(for account: String) -> String?
  /// 是否已存有该条（不读明文——启动检查用，见 KeychainAIKeyStorage.exists）
  func exists(for account: String) -> Bool
  /// value 为 nil 或空串时删除该条
  func set(_ value: String?, for account: String)
}

/// Keychain 实现：generic password，service 固定、account = Provider rawValue。
/// 不加 kSecAttrAccessible 限定（默认 unlocked-when-unlocked，本机可读）。
struct KeychainAIKeyStorage: AIKeyStorage {
  private let service = "com.whyluna.markpdf.ai"

  func string(for account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 只查存在性、不读明文数据：钥匙串 ACL 只保护 kSecValueData，查属性不弹授权窗。
  /// ad-hoc 签名（无开发证书）下每次构建二进制指纹变化，启动即读明文会导致
  /// 每次 build 后启动都弹「输入钥匙串密码」——启动检查必须走此通道
  func exists(for account: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  func set(_ value: String?, for account: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    guard let value, !value.isEmpty else {
      SecItemDelete(base as CFDictionary)
      return
    }
    let data = Data(value.utf8)
    let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = base
      item[kSecValueData as String] = data
      SecItemAdd(item as CFDictionary, nil)
    }
  }
}

/// API Key 门面（FR-AI.4）：Key 本体只经 apiKey(for:) 取出送进请求头，
/// UI 只观察「已配置」集合做状态展示，永不回显明文。
/// 内存实现（InMemoryAIKeyStorage）在测试 target（MarkPDFTests/TestAIHelpers.swift）
@MainActor
final class AIKeyStore: ObservableObject {
  /// 已保存 Key 的 account（Provider rawValue）集合
  @Published private(set) var configuredAccounts: Set<String>

  private let storage: AIKeyStorage

  init(storage: AIKeyStorage = KeychainAIKeyStorage()) {
    self.storage = storage
    // 启动只查存在性不读明文（读明文会在 ad-hoc 签名下每次 build 后弹钥匙串授权）
    configuredAccounts = Set(AIProviderKind.allCases.map(\.rawValue).filter { storage.exists(for: $0) })
  }

  func apiKey(for account: String) -> String? {
    storage.string(for: account)
  }

  func save(_ key: String, for account: String) {
    // 粘贴自网页/密码管理器的 key 常带换行或空格：CFNetwork 会静默丢弃含 \n 的
    // 头值（请求不带鉴权发出、全线 401 且极难排查），保存前清洗
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    storage.set(trimmed, for: account)
    // 空串在存储层视为删除，状态集合同步口径
    if trimmed.isEmpty {
      configuredAccounts.remove(account)
    } else {
      configuredAccounts.insert(account)
    }
  }

  func remove(for account: String) {
    storage.set(nil, for: account)
    configuredAccounts.remove(account)
  }
}
