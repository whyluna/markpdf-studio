import Foundation
@testable import MarkPDF

/// AI 相关测试的共享替身/助手

/// 内存版 Key 存储（测试用）：与 Keychain 实现同一 AIKeyStorage 协议
final class InMemoryAIKeyStorage: AIKeyStorage {
  private var map: [String: String] = [:]

  func string(for account: String) -> String? { map[account] }

  func exists(for account: String) -> Bool { map[account] != nil }

  @discardableResult
  func set(_ value: String?, for account: String) -> Bool {
    guard let value, !value.isEmpty else {
      map.removeValue(forKey: account)
      return true
    }
    map[account] = value
    return true
  }
}

/// 写入恒失败的 Key 存储（回归：Keychain 拒绝时不得把 account 标成「已配置」）
final class FailingAIKeyStorage: AIKeyStorage {
  func string(for account: String) -> String? { nil }
  func exists(for account: String) -> Bool { false }
  func set(_ value: String?, for account: String) -> Bool { false }
}
