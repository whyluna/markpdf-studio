import AppKit
import SwiftUI

/// 内容小于视口时保持居中的 ClipView（macOS 标准做法）：
/// 文档视图几何完全不动，仅在约束 bounds 时把原点平移到文档中心——
/// 不会像改 frame / contentInsets 那样与原生缩放锚点打架（缩放乱窜、滚轴抖动的根因）。
final class CenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    guard let documentView else { return rect }
    if documentView.frame.width < rect.width {
      rect.origin.x = (documentView.frame.width - rect.width) / 2
    }
    if documentView.frame.height < rect.height {
      rect.origin.y = (documentView.frame.height - rect.height) / 2
    }
    return rect
  }
}

/// 图片预览（FR-3.2 同款缩放）：NSScrollView 原生捏合缩放 + ⌘= / ⌘- / ⌘0 快捷键。
/// 打开自动适应视图并居中；⌘0 回到实际像素大小。
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
    // 覆盖式滚动条（不占布局空间）
    scrollView.scrollerStyle = .overlay
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    // 捏合缩放走 NSScrollView 原生通道（流畅、锚点正确）
    scrollView.allowsMagnification = true
    scrollView.minMagnification = ImagePreviewStore.minScale
    scrollView.maxMagnification = ImagePreviewStore.maxScale

    let clipView = CenteringClipView()
    clipView.drawsBackground = false
    scrollView.contentView = clipView

    let imageView = NSImageView()
    // 按原始像素布局，缩放交给 scrollView.magnification
    imageView.imageScaling = .scaleNone
    scrollView.documentView = imageView
    // 解码完成并适应视图前隐藏，避免未居中时闪一下
    scrollView.alphaValue = 0

    context.coordinator.scrollView = scrollView
    // 缩放变化 KVO：手势中防抖刷新 SVG 栅格（保持清晰）
    context.coordinator.magnificationObserver = scrollView.observe(\.magnification, options: [.new]) { [weak coordinator = context.coordinator] scrollView, _ in
      coordinator?.magnificationDidChange(scrollView.magnification)
    }

    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.liveMagnifyEnded(_:)),
      name: NSScrollView.didEndLiveMagnifyNotification,
      object: scrollView
    )
    // 后台解码（SVG 一并预栅格化），完成后主线程挂载并适应视图
    context.coordinator.loadImage(url: url)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    if context.coordinator.currentURL != url {
      context.coordinator.currentURL = url
      // 后台解码新图（旧图保持显示到解码完成，避免闪烁）；在途旧解码结果由代际号作废
      context.coordinator.loadImage(url: url)
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
    coordinator.magnificationObserver?.invalidate()
    coordinator.magnificationObserver = nil
    coordinator.rasterDebouncer.cancel()
    coordinator.invalidate()
    NotificationCenter.default.removeObserver(coordinator)
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: ImagePreviewView
    weak var scrollView: NSScrollView?
    var currentURL: URL
    /// 原始图片（SVG 为矢量源）
    var baseImage: NSImage?
    /// 当前栅格化倍率（0 = 未栅格化）
    var rasterScale: CGFloat = 0
    /// SVG 栅格刷新防抖器
    let rasterDebouncer = Debouncer(interval: 0.4)
    /// 缩放 KVO 观察（手势中防抖重绘栅格）
    var magnificationObserver: NSKeyValueObservation?
    private var didReveal = false
    /// 解码/栅格化代际号：视图复用（URL 切换）或拆除时丢弃过期结果
    private var loadToken = 0
    /// 后台串行队列：图片解码与 SVG 栅格化（主线程不做同步解码）
    private let workQueue = DispatchQueue(label: "markpdf.image-preview")
    /// 解码中的加载指示（沿用 PDF 阅读器的加载态风格）
    private var spinner: NSProgressIndicator?

    /// 矢量图（SVG）：AppKit 每次缩放都会重新栅格化（卡顿根因），
    /// 故预先栅格化为高清位图，缩放交给 GPU
    private var isVector: Bool {
      Self.isVectorURL(currentURL)
    }

    private static func isVectorURL(_ url: URL) -> Bool {
      (url.pathExtension as NSString).lowercased == "svg"
    }

    init(_ parent: ImagePreviewView) {
      self.parent = parent
      self.currentURL = parent.url
    }

    /// 异步加载图片：后台解码（SVG 按初始倍率一并预栅格化），完成后主线程挂载并适应视图。
    /// 代际号防视图复用竞态：解码回来时 URL 已切换（或视图已拆除）则丢弃结果
    func loadImage(url: URL) {
      loadToken += 1
      let token = loadToken
      let isVector = Self.isVectorURL(url)
      showSpinner(true)
      workQueue.async { [weak self] in
        let decoded = NSImage(contentsOf: url)
        // SVG：首次栅格化也在后台完成（目标倍率与 applyRaster 同式），主线程不再同步栅格
        var raster: (image: NSImage, scale: CGFloat)?
        if isVector, let decoded {
          raster = Self.rasterize(decoded, atLeast: 1)
        }
        DispatchQueue.main.async { [weak self] in
          guard let self, token == self.loadToken, self.currentURL == url else { return }
          self.showSpinner(false)
          self.baseImage = decoded
          self.imageViewImage = raster?.image
          self.rasterScale = raster?.scale ?? 0
          let imageView = self.scrollView?.documentView as? NSImageView
          imageView?.image = self.displayImage()
          if let size = imageView?.image?.size {
            imageView?.frame = NSRect(origin: .zero, size: size)
          }
          self.fitToView()
        }
      }
    }

    /// 视图拆除：作废在途解码/栅格化结果
    func invalidate() {
      loadToken += 1
      showSpinner(false)
    }

    /// 解码中的旋转指示（完成或失败后移除）
    private func showSpinner(_ show: Bool) {
      if show {
        guard spinner == nil, let scrollView else { return }
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .large
        indicator.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(indicator)
        NSLayoutConstraint.activate([
          indicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
          indicator.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        indicator.startAnimation(nil)
        spinner = indicator
      } else {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
      }
    }

    /// 当前应显示的图片：矢量图返回已栅格化位图（未就绪时退回矢量源），位图原样返回
    func displayImage() -> NSImage? {
      guard let baseImage else { return nil }
      guard isVector else { return baseImage }
      return imageViewImage ?? baseImage
    }

    /// 已生成的栅格位图
    private var imageViewImage: NSImage?

    /// 按需栅格化：目标倍率跟随实际缩放（下限 2 保证初始清晰），
    /// 像素尺寸封顶 6000；目标高于当前缓存 5% 才重绘（SVG 矢量重栅格化）。
    /// 栅格化在后台串行队列执行、完成后主线程挂载；
    /// 落地时 URL 已切换或已有更新的缓存（更新的请求先行落地）则丢弃
    func applyRaster(atLeast scale: CGFloat) {
      guard isVector, let baseImage else { return }
      let size = baseImage.size
      let pixelCap: CGFloat = 6000
      let target = min(max(scale, 2.0), ImagePreviewStore.maxScale, pixelCap / max(size.width, size.height))
      guard target > rasterScale * 1.05 else { return }
      let token = loadToken
      workQueue.async { [weak self] in
        guard let raster = Self.rasterize(baseImage, atLeast: scale) else { return }
        DispatchQueue.main.async { [weak self] in
          guard let self, token == self.loadToken, raster.scale > self.rasterScale * 1.05 else { return }
          self.imageViewImage = raster.image
          self.rasterScale = raster.scale
          if let imageView = self.scrollView?.documentView as? NSImageView {
            imageView.image = raster.image
          }
        }
      }
    }

    /// 生成栅格位图（后台线程安全：只读传入的 baseImage，不触碰视图状态）。
    /// 返回位图与实际倍率；尺寸非法返回 nil
    private static func rasterize(_ baseImage: NSImage, atLeast scale: CGFloat) -> (image: NSImage, scale: CGFloat)? {
      let size = baseImage.size
      let pixelCap: CGFloat = 6000
      let target = min(max(scale, 2.0), ImagePreviewStore.maxScale, pixelCap / max(size.width, size.height))
      let width = Int(size.width * target)
      let height = Int(size.height * target)
      guard width > 0, height > 0 else { return nil }
      guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ) else { return nil }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      baseImage.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
      NSGraphicsContext.restoreGraphicsState()
      let raster = NSImage(size: size) // 逻辑尺寸不变，布局/居中计算不受影响
      raster.addRepresentation(rep)
      return (raster, target)
    }

    /// 缩放变化（KVO）：防抖 400ms 刷新 SVG 栅格，手势中保持清晰、静止时对齐缩放
    ///（栅格化在后台执行，完成后自行挂载）
    func magnificationDidChange(_ magnification: CGFloat) {
      guard isVector else { return }
      rasterDebouncer.schedule { [weak self] in
        self?.applyRaster(atLeast: magnification)
      }
    }

    /// 适应视图（恰好容纳整张图，小图不超过实际像素），完成后首次显示
    func fitToView() {
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
        self.applyRaster(atLeast: scale)
        if !self.didReveal {
          self.didReveal = true
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            scrollView.animator().alphaValue = 1
          }
        }
      }
    }

    /// 可视区中心（文档坐标，⌘ 缩放的锚点）
    func visibleCenterInDocument() -> NSPoint {
      guard let scrollView else { return .zero }
      let visible = scrollView.contentView.bounds
      return NSPoint(x: visible.midX, y: visible.midY)
    }

    /// 捏合结束：回写缩放状态（异步，避免在视图更新途中发布 @Published）；
    /// SVG 按需刷新栅格（放大超过缓存倍率后保持清晰；栅格化在后台执行，完成后自行挂载）
    @objc func liveMagnifyEnded(_ note: Notification) {
      guard let scrollView else { return }
      let scale = scrollView.magnification
      applyRaster(atLeast: scale)
      DispatchQueue.main.async { [weak self] in
        self?.parent.imageStore.scale = scale
      }
    }
  }
}

#Preview {
  ImagePreviewView(url: URL(fileURLWithPath: "/tmp/demo.png"))
    .environmentObject(ImagePreviewStore())
    .frame(width: 640, height: 480)
}
