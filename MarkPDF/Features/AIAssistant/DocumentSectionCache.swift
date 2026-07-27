import Foundation
import PDFKit

/// 文档切节缓存（FR-AI.2 v1.2 性能）：key = 路径 + mtime + 大小（文件变即失效）。
/// 懒缓存：首次切节时写入；打开 PDF 标签时预热当前文档（首次提问也快）。
/// 线程安全（NSLock）：主线程（当前文档路由）与后台（工作区检索/预热）共用
final class DocumentSectionCache: @unchecked Sendable {
  static let shared = DocumentSectionCache()

  /// 缓存文件数上限（节含全文文本，FIFO 逐出控内存）
  private let limit = 8
  private let lock = NSLock()
  private var cache: [String: (stamp: String, sections: [DocumentSection])] = [:]
  private var order: [String] = []

  /// 命中返回缓存；未中执行 compute 并写入（compute 返回 nil/空不缓存）
  func sections(for url: URL, compute: () -> [DocumentSection]?) -> [DocumentSection]? {
    let key = url.standardizedFileURL.path
    let stamp = Self.stamp(for: url)
    lock.lock()
    if let entry = cache[key], entry.stamp == stamp {
      let hit = entry.sections
      lock.unlock()
      return hit
    }
    lock.unlock()

    guard let computed = compute(), !computed.isEmpty else { return nil }
    lock.lock()
    if cache[key] == nil {
      order.append(key)
      if order.count > limit {
        cache.removeValue(forKey: order.removeFirst())
      }
    }
    cache[key] = (stamp, computed)
    lock.unlock()
    return computed
  }

  /// 是否已有有效缓存（预热判断用，不触发计算）
  func isCached(_ url: URL) -> Bool {
    let key = url.standardizedFileURL.path
    let stamp = Self.stamp(for: url)
    lock.lock()
    defer { lock.unlock() }
    return cache[key]?.stamp == stamp
  }

  /// 文件指纹：mtime + 大小。用 FileManager 而非 URL.resourceValues——
  /// 后者对同一 URL 实例有缓存，文件变更后读到旧值（缓存永不失效实锤）
  private static func stamp(for url: URL) -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    let size = (attributes?[.size] as? Int) ?? -1
    return "\(mtime)-\(size)"
  }
}
