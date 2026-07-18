import CoreServices
import Foundation

/// 工作区目录监听服务（FR-1.3）：外部变更（Finder 增删改）时回调，驱动文件树自动刷新。
/// 协议化（开发规范 §3.2）：测试可注入 mock。
protocol FileWatcher {
  /// 递归监听目录；回调在主线程触发，已做 300ms 防抖合并（§9.3）
  func startWatching(url: URL, onChange: @escaping () -> Void)
  func stopWatching()
}

final class LiveFileWatcher: FileWatcher {
  private var stream: FSEventStreamRef?
  private var onChange: (() -> Void)?
  private let debouncer = Debouncer(interval: 0.3)

  func startWatching(url: URL, onChange: @escaping () -> Void) {
    stopWatching()
    self.onChange = onChange

    var context = FSEventStreamContext()
    context.info = Unmanaged.passUnretained(self).toOpaque()
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<LiveFileWatcher>.fromOpaque(info).takeUnretainedValue()
      watcher.debouncer.schedule {
        watcher.onChange?()
      }
    }
    let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
    guard let stream = FSEventStreamCreate(
      nil,
      callback,
      &context,
      [url.path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.3,
      flags
    ) else { return }

    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    FSEventStreamStart(stream)
  }

  func stopWatching() {
    debouncer.cancel()
    onChange = nil
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
  }

  deinit {
    stopWatching()
  }
}
