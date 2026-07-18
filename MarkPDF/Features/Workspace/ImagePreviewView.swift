import AppKit
import SwiftUI

/// 图片预览（FR-3.2 同款缩放）：NSScrollView 原生捏合缩放 + ⌘= / ⌘- / ⌘0 快捷键。
/// 打开时自动适应视图；⌘0 回到实际像素大小。
struct ImagePreviewView: NSViewRepresentable {
  let url: URL
  @EnvironmentObject private var imageStore: ImagePreviewStore

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    // 捏合缩放走 NSScrollView 原生通道（流畅、锚点正确）
    scrollView.allowsMagnification = true
    scrollView.minMagnification = ImagePreviewStore.minScale
    scrollView.maxMagnification = ImagePreviewStore.maxScale

    let imageView = NSImageView()
    imageView.image = NSImage(contentsOf: url)
    // 按原始像素布局，缩放交给 scrollView.magnification
    imageView.imageScaling = .scaleNone
    if let size = imageView.image?.size {
      imageView.frame = NSRect(origin: .zero, size: size)
    }
    scrollView.documentView = imageView

    context.coordinator.scrollView = scrollView
    context.coordinator.fitToView()
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.liveMagnifyEnded(_:)),
      name: NSScrollView.didEndLiveMagnifyNotification,
      object: scrollView
    )
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    if context.coordinator.currentURL != url {
      (scrollView.documentView as? NSImageView)?.image = NSImage(contentsOf: url)
      context.coordinator.currentURL = url
      context.coordinator.fitToView()
      return
    }
    // 外部驱动缩放（⌘ 快捷键 / 状态栏按钮），以可视中心为锚
    if abs(scrollView.magnification - imageStore.scale) > 0.001 {
      scrollView.setMagnification(
        ImagePreviewStore.clamped(imageStore.scale),
        centeredAt: context.coordinator.visibleCenterInDocument()
      )
    }
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(coordinator)
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: ImagePreviewView
    weak var scrollView: NSScrollView?
    var currentURL: URL

    init(_ parent: ImagePreviewView) {
      self.parent = parent
      self.currentURL = parent.url
    }

    /// 适应视图：恰好容纳整张图（小图不放大超过实际像素）
    func fitToView() {
      // 布局未完成时延后一拍
      DispatchQueue.main.async { [weak self] in
        guard let self, let scrollView = self.scrollView,
          let image = (scrollView.documentView as? NSImageView)?.image
        else { return }
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let fit = min(contentSize.width / image.size.width, contentSize.height / image.size.height, 1.0)
        let scale = ImagePreviewStore.clamped(fit)
        scrollView.magnification = scale
        self.parent.imageStore.scale = scale
      }
    }

    /// 可视区中心（文档坐标，⌘ 缩放的锚点）
    func visibleCenterInDocument() -> NSPoint {
      guard let scrollView else { return .zero }
      let visible = scrollView.contentView.bounds
      return NSPoint(x: visible.midX, y: visible.midY)
    }

    /// 捏合结束：回写缩放状态
    @objc func liveMagnifyEnded(_ note: Notification) {
      guard let scrollView else { return }
      parent.imageStore.scale = scrollView.magnification
    }
  }
}

#Preview {
  ImagePreviewView(url: URL(fileURLWithPath: "/tmp/demo.png"))
    .environmentObject(ImagePreviewStore())
    .frame(width: 640, height: 480)
}
