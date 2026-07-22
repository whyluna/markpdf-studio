import CoreServices
import Foundation

/// 工作区统一排除目录名单（FR-1.1 性能：node_modules 动辄上万文件）。
/// 目录扫描（WorkspaceStore）与 FSEvents 事件过滤（LiveFileWatcher）共用同一份名单与判定，
/// 避免两处手写漂移。
enum WorkspaceExcludedDirectories {
  /// 跳过的大型依赖/版本控制/构建产物目录。
  /// 保持原始大小写：WorkspaceStore 扫描按 lastPathComponent 精确匹配使用该名单（语义不变）；
  /// isExcluded 的大小写不敏感判定走 lowercasedNames。
  static let names: Set<String> = [
    "node_modules", ".git", ".svn", ".hg", ".build", ".xcodeproj", "DerivedData",
    "Pods", "Carthage", ".venv", "__pycache__", "target", "dist", "build", ".next", "vendor",
  ]

  /// 小写副本：事件过滤判定大小写不敏感（Node_Modules 这类写法也挡）
  private static let lowercasedNames = Set(names.map { $0.lowercased() })

  /// 事件路径是否落在排除目录子树内（相对监听根目录判定，与扫描排除语义一致）。
  /// 只判定根目录以下的相对部分：根目录自身路径若恰含同名目录（如 DerivedData）不影响监听。
  /// 按路径分段精确匹配（与扫描的 lastPathComponent 判定同口径），"node_modules_backup" 不误伤。
  static func isExcluded(eventPath: String, watchedRoot: String) -> Bool {
    var root = watchedRoot
    while root.hasSuffix("/") { root = String(root.dropLast()) }
    var relative = eventPath
    if relative.hasPrefix(root + "/") {
      relative = String(relative.dropFirst(root.count + 1))
    } else if relative == root {
      // 根目录自身的变更事件：不过滤
      return false
    }
    return (relative as NSString).pathComponents.contains { lowercasedNames.contains($0.lowercased()) }
  }
}

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
  /// 监听根目录（用于排除目录子树过滤）
  private var watchedRoot: String?

  func startWatching(url: URL, onChange: @escaping () -> Void) {
    stopWatching()
    self.onChange = onChange
    self.watchedRoot = url.path

    var context = FSEventStreamContext()
    context.info = Unmanaged.passUnretained(self).toOpaque()
    let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<LiveFileWatcher>.fromOpaque(info).takeUnretainedValue()
      // kFSEventStreamCreateFlagUseCFTypes：eventPaths 实为 CFArray<CFString>
      let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
      watcher.handleEvents(paths: paths)
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

  /// FSEvents 事件入口：先按路径过滤——全部落在排除目录子树内（如 node_modules 的
  /// npm install 海量事件）直接丢弃，不再引发全量重扫；存在有效事件才防抖触发。
  private func handleEvents(paths: [String]) {
    guard let watchedRoot else { return }
    guard paths.contains(where: { !WorkspaceExcludedDirectories.isExcluded(eventPath: $0, watchedRoot: watchedRoot) })
    else { return }
    debouncer.schedule { [weak self] in
      self?.onChange?()
    }
  }

  func stopWatching() {
    debouncer.cancel()
    onChange = nil
    watchedRoot = nil
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
