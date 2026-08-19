import Foundation
import os

/// API Key 容器文件存储（FR-AI.4 调整，2026-08-19）：
/// ad-hoc 签名（无开发证书）分发模式下二进制指纹每次构建都变，
/// 登录钥匙串条目的 ACL 认不出新二进制——每次更新后首次用 AI 都会弹
/// 「想要使用钥匙串」系统授权窗，取消即「未配置 API Key」（实测用户现场）。
/// 文件存容器内（沙盒保护 + 0600 权限），跨构建稳定，零弹窗。
/// 钥匙串实现保留：Hybrid 读旧值用（见 HybridAIKeyStorage），正式签名发布可切回。
struct ContainerFileKeyStorage: AIKeyStorage {
  /// 存储目录（生产 = 沙盒容器 Application Support/MarkPDF；测试注入临时目录）
  private let directory: URL

  init(directory: URL? = nil) {
    if let directory {
      self.directory = directory
    } else {
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      self.directory = base.appendingPathComponent("MarkPDF", isDirectory: true)
    }
  }

  private var fileURL: URL { directory.appendingPathComponent("api-keys.json") }

  private func load() -> [String: String] {
    guard let data = try? Data(contentsOf: fileURL),
      let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    else { return [:] }
    return map
  }

  private func persist(_ map: [String: String]) -> Bool {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard let data = try? JSONSerialization.data(withJSONObject: map) else { return false }
      try data.write(to: fileURL, options: [.atomic])
      // 0600：仅本用户可读（容器目录本身已受沙盒保护，双保险）
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      return true
    } catch {
      Logger.ai.error("API Key 容器文件写入失败: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  func string(for account: String) -> String? {
    load()[account]
  }

  func exists(for account: String) -> Bool {
    load()[account] != nil
  }

  @discardableResult
  func set(_ value: String?, for account: String) -> Bool {
    var map = load()
    if let value, !value.isEmpty {
      map[account] = value
    } else {
      guard map.removeValue(forKey: account) != nil else { return true }
    }
    return persist(map)
  }
}

/// 混合存储：读 = 容器文件 → 钥匙串（旧值兼容）；写 = 容器文件 + 尽力清掉钥匙串旧条目
///（清不掉也无害——读永远先走文件，旧条目只是无人问津的孤儿）。
/// 用户侧迁移路径：重新粘贴一次 Key 即落进文件；或在连接测试读到旧值后由保存动作完成迁移。
struct HybridAIKeyStorage: AIKeyStorage {
  private let file: ContainerFileKeyStorage
  /// 钥匙串腿走协议：生产 KeychainAIKeyStorage，测试可注入替身
  private let keychain: AIKeyStorage

  init(
    file: ContainerFileKeyStorage = ContainerFileKeyStorage(),
    keychain: AIKeyStorage = KeychainAIKeyStorage()
  ) {
    self.file = file
    self.keychain = keychain
  }

  func string(for account: String) -> String? {
    if let value = file.string(for: account) { return value }
    // 旧值兼容：钥匙串里能读到就用到（可能触发一次系统授权窗——最后一次）
    return keychain.string(for: account)
  }

  func exists(for account: String) -> Bool {
    file.exists(for: account) || keychain.exists(for: account)
  }

  @discardableResult
  func set(_ value: String?, for account: String) -> Bool {
    guard file.set(value, for: account) else { return false }
    // 尽力移除钥匙串旧条目：此后任何构建都不再弹授权窗；失败静默（孤儿条目无害）
    _ = keychain.set(nil, for: account)
    return true
  }
}
