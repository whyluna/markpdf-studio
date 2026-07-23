import Foundation
@testable import MarkPDF

/// AI 相关测试的共享替身/助手

/// 内存版 Key 存储（测试用）：与 Keychain 实现同一 AIKeyStorage 协议
final class InMemoryAIKeyStorage: AIKeyStorage {
  private var map: [String: String] = [:]

  func string(for account: String) -> String? { map[account] }

  func set(_ value: String?, for account: String) {
    guard let value, !value.isEmpty else {
      map.removeValue(forKey: account)
      return
    }
    map[account] = value
  }
}
