import Foundation

/// 通用防抖器（开发规范 §9.3）：合并短时间内的连续触发，只执行最后一次。
final class Debouncer {
  private let interval: TimeInterval
  private let queue: DispatchQueue
  private var item: DispatchWorkItem?

  init(interval: TimeInterval, queue: DispatchQueue = .main) {
    self.interval = interval
    self.queue = queue
  }

  func schedule(_ action: @escaping () -> Void) {
    item?.cancel()
    let item = DispatchWorkItem(block: action)
    self.item = item
    queue.asyncAfter(deadline: .now() + interval, execute: item)
  }

  func cancel() {
    item?.cancel()
    item = nil
  }

  /// 立即执行挂起的动作（若有），不再等待间隔（退出/拆除前的兜底落盘）
  func fire() {
    guard let item else { return }
    self.item = nil
    item.cancel()
    item.perform()
  }
}
