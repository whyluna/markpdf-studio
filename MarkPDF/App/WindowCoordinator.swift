import AppKit
import Foundation

/// 窗口注册表（v1.5 多窗口，App 级）：live sessions 的登记/注销与全量 flush。
/// ② 扩展为路由中枢（已开则聚焦 / 新窗请求队列）
@MainActor
final class WindowCoordinator: ObservableObject {
  private(set) var sessions: [WindowSession] = []

  /// 登记窗口 session（幂等）；返回是否首个窗口（首窗负责启动恢复与外部打开接线）
  @discardableResult
  func register(_ session: WindowSession) -> Bool {
    if let index = sessions.firstIndex(where: { $0 === session }) {
      return index == 0
    }
    sessions.append(session)
    return sessions.count == 1
  }

  func unregister(_ session: WindowSession) {
    sessions.removeAll { $0 === session }
  }

  /// 退出前兜底：逐窗口落盘（标签/标注/快照/AI 会话）
  func flushAll() {
    for session in sessions {
      session.flush()
    }
  }
}
