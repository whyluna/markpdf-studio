import Foundation
import os
import Security

/// API Key 存储抽象（FR-AI.4）：生产走系统钥匙串，测试走内存
protocol AIKeyStorage {
  func string(for account: String) -> String?
  /// 是否已存有该条（不读明文——启动检查用，见 KeychainAIKeyStorage.exists）
  func exists(for account: String) -> Bool
  /// value 为 nil 或空串时删除该条；返回是否写入成功（锁屏等场景 Keychain 会拒绝）
  @discardableResult func set(_ value: String?, for account: String) -> Bool
}

/// Keychain 实现：generic password，service 固定、account = Provider rawValue。
/// 不加 kSecAttrAccessible 限定（默认 unlocked-when-unlocked，本机可读）。
struct KeychainAIKeyStorage: AIKeyStorage {
  private let service: String

  /// service 可注入：测试用一次性随机名在真实钥匙串上验证行为，不碰用户条目
  init(service: String = "com.whyluna.markpdf.ai") {
    self.service = service
  }

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

  @discardableResult
  func set(_ value: String?, for account: String) -> Bool {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    guard let value, !value.isEmpty else {
      SecItemDelete(base as CFDictionary)
      return true
    }
    let data = Data(value.utf8)
    /// 删旧重建：新条目由当前二进制创建，ACL 立即匹配（旧条目在重签名后可能
    /// 「更新被放行、读取被拒绝」——2026-08-19 现场，删除重建是唯一自愈路径）
    func addFresh() -> Bool {
      SecItemDelete(base as CFDictionary)
      var item = base
      item[kSecValueData as String] = data
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        Logger.ai.error("API Key 写入钥匙串失败（重建 add=\(addStatus)）")
        return false
      }
      return true
    }
    let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound:
      if status == errSecItemNotFound, !addFresh() { return false }
    case errSecAuthFailed, errSecMissingEntitlement:
      // ad-hoc 签名每次构建二进制指纹变化，旧条目 ACL 不认当前二进制 → 删旧重建。
      // 锁屏（errSecInteractionNotAllowed）等其他错误不删条目（保住旧值），直接失败
      if !addFresh() { return false }
    default:
      Logger.ai.error("API Key 写入钥匙串失败（update=\(status)）")
      return false
    }
    // 后置条件：返回 true 即「当前二进制可读」。写成功但读不回（ACL 只拒读）→
    // 删旧重建一次；重建后仍读不回属于环境级拒绝，如实报失败
    if string(for: account) != value {
      Logger.ai.notice("API Key 条目写后读不回，删旧重建（签名更新自愈）: \(account, privacy: .public)")
      guard addFresh(), string(for: account) == value else {
        Logger.ai.error("API Key 钥匙串条目重建后仍不可读（update=\(status)）")
        return false
      }
    }
    return true
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

  /// 默认走混合存储（容器文件为主、钥匙串只读兼容——2026-08-19 钥匙串弹窗问题的根治，
  /// 见 HybridAIKeyStorage 注释）；测试注入内存/纯文件实现
  init(storage: AIKeyStorage = HybridAIKeyStorage()) {
    self.storage = storage
    // 启动只查存在性（混合存储的存在性检查不读钥匙串明文，不弹授权窗）
    configuredAccounts = Set(AIProviderKind.allCases.map(\.rawValue).filter { storage.exists(for: $0) })
  }

  func apiKey(for account: String) -> String? {
    storage.string(for: account)
  }

  /// 钥匙串写入失败提示（设置页据此弹 alert；NFR-5：失败须用户可感知）
  @Published var lastError: String?

  @discardableResult
  func save(_ key: String, for account: String) -> Bool {
    // 粘贴自网页/密码管理器的 key 常带换行或空格：CFNetwork 会静默丢弃含 \n 的
    // 头值（请求不带鉴权发出、全线 401 且极难排查），保存前清洗
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard storage.set(trimmed, for: account) else {
      lastError = String(localized: "API Key 未能写入系统钥匙串（可能处于锁屏状态），请解锁后重试。")
      return false
    }
    // 写后读回校验：钥匙串存在「写成功但读不出」（ACL 拒绝旧条目）状态——
    // 不校验会出现「显示已配置、请求报未配置」的矛盾（2026-08-19 现场）。
    // 读不回即删掉刚写的不可用条目（草稿保留在输入框，用户重粘即可）
    if !trimmed.isEmpty, storage.string(for: account) != trimmed {
      storage.set(nil, for: account)
      lastError = String(localized: "API Key 已写入但系统拒绝本应用读取（应用重新签名后会出现一次）。请重新粘贴并再点一次「保存」；若仍失败，请在「钥匙串访问」中删除 MarkPDF 的条目后重试。")
      return false
    }
    // 空串在存储层视为删除，状态集合同步口径
    if trimmed.isEmpty {
      configuredAccounts.remove(account)
    } else {
      configuredAccounts.insert(account)
    }
    return true
  }

  func remove(for account: String) {
    storage.set(nil, for: account)
    configuredAccounts.remove(account)
  }
}
