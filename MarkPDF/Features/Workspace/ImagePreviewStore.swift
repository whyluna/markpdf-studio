import Foundation

/// 图片预览状态（缩放；Scene 级持有）。
@MainActor
final class ImagePreviewStore: ObservableObject, ZoomTarget {
  /// 缩放倍率（1.0 = 实际像素大小；打开时自动调整为适应视图）
  @Published var scale: CGFloat = 1.0

  static let minScale: CGFloat = 0.1
  static let maxScale: CGFloat = 8.0
  static let factor: CGFloat = 1.25

  static func clamped(_ value: CGFloat) -> CGFloat {
    min(max(value, minScale), maxScale)
  }

  func zoomIn() {
    scale = Self.clamped(scale * Self.factor)
  }

  func zoomOut() {
    scale = Self.clamped(scale / Self.factor)
  }

  /// 实际大小（100%）
  func resetZoom() {
    scale = 1.0
  }
}
