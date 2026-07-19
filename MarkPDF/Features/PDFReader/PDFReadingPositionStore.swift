import Foundation

/// PDF 阅读位置记忆（FR-3.5）：按文件路径持久化「页码 + 缩放」，重开自动恢复。
/// 存 UserDefaults（与 PDFBookmarksStore 同模式；注入 defaults 便于测试）。
@MainActor
final class PDFReadingPositionStore: ObservableObject {
  /// 单文件的阅读位置快照
  struct Position: Equatable {
    /// 1 起页码
    let page: Int
    let scale: Double
  }

  private let defaults: UserDefaults
  private static let defaultsKey = "pdfReadingPositions"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 读取某文件的上次阅读位置；无存档或数据损坏返回 nil（走默认自适应宽度）
  func position(for url: URL) -> Position? {
    guard let dict = defaults.dictionary(forKey: Self.defaultsKey)?[url.path] as? [String: Any],
      let page = dict["page"] as? Int, page >= 1,
      let scale = dict["scale"] as? Double, scale > 0
    else { return nil }
    return Position(page: page, scale: scale)
  }

  /// 记录某文件的阅读位置（覆盖式）
  func save(_ position: Position, for url: URL) {
    var all = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Any]] ?? [:]
    all[url.path] = ["page": position.page, "scale": position.scale]
    defaults.set(all, forKey: Self.defaultsKey)
  }
}
