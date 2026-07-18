import Foundation

/// PDF 阅读状态（FR-3.1/3.2）：页码、缩放；Scene 级持有。
@MainActor
final class PDFReaderStore: ObservableObject {
  /// 当前页（1 起；0 = 无文档）
  @Published var currentPage = 0
  /// 总页数
  @Published var pageCount = 0
  /// 缩放倍率（1.0 = 100%）
  @Published var scale: CGFloat = 1.0

  static let minScale: CGFloat = 0.5
  static let maxScale: CGFloat = 4.0
  static let step: CGFloat = 0.25

  /// 夹取到 FR-3.2 范围（50%–400%）
  static func clamped(_ value: CGFloat) -> CGFloat {
    min(max(value, minScale), maxScale)
  }

  func zoomIn() {
    scale = Self.clamped(scale + Self.step)
  }

  func zoomOut() {
    scale = Self.clamped(scale - Self.step)
  }

  func resetZoom() {
    scale = 1.0
  }
}
