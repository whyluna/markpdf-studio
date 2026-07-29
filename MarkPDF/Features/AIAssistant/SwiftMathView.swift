import SwiftUI
import SwiftMath

/// SwiftMath 原生公式排版（FR-AI.2，替换「一公式一 WKWebView/KaTeX」方案）：
/// CoreText + TeX 数学字体，同步布局——无异步高度回填（滚动条不再跳变）、
/// 无 WebView 进程开销、无跨视图选区割裂。
/// 块级：SwiftMathBlockView（labelMode .display，同步尺寸出现即最终高度，超宽横滑）；
/// 行内：渲染为 2x 位图内联进 Text 流（随文字换行，参与原生选区）。
@MainActor
enum SwiftMathRenderer {
  /// 行内位图缓存（key = 字号|latex）
  private static var imageCache: [String: (image: NSImage, size: CGSize)] = [:]

  /// 同步量取排版尺寸（无 JS、无异步——滚动稳定的关键）。
  /// 用 sizeThatFits 无限宽度量取自然尺寸：MTMathUILabel 会按当前帧宽自动换行，
  /// intrinsicContentSize 在宽公式下量出「换行后尺寸」≠ 实际渲染需要（实测被裁剪）
  static func measure(latex: String, fontSize: CGFloat, displayMode: Bool) -> CGSize {
    let label = MTMathUILabel()
    label.fontSize = fontSize
    label.labelMode = displayMode ? .display : .text
    label.latex = latex
    // 宽度上限 2000pt：typesetter 内部 em 定点数，更大值会溢出导致意外换行
    let size = label.sizeThatFits(
      CGSize(width: 2_000, height: CGFloat.greatestFiniteMagnitude)
    )
    return CGSize(width: ceil(size.width), height: ceil(size.height))
  }

  /// 同步渲染为 2x 位图（行内混排片段用；TeX 排版质量、随文字流换行）
  static func image(latex: String, fontSize: CGFloat) -> (image: NSImage, size: CGSize)? {
    let key = "\(fontSize)|\(latex)"
    if let cached = imageCache[key] { return cached }
    let size = measure(latex: latex, fontSize: fontSize, displayMode: false)
    guard size.width > 1, size.height > 1 else { return nil }
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width * scale),
      pixelsHigh: Int(size.height * scale),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    let label = MTMathUILabel()
    label.fontSize = fontSize
    label.labelMode = .text
    label.latex = latex
    label.frame = NSRect(origin: .zero, size: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    label.layoutSubtreeIfNeeded()
    label.draw(label.bounds)
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    imageCache[key] = (image, size)
    return (image, size)
  }

  /// 行内片段：文本段（继续走 markdown 行内样式）与公式段（位图内联）
  enum InlineSegment: Equatable {
    case text(String)
    case math(String)
  }

  /// 按未转义 $ 切段（奇数个 $ 时尾段按普通文本回落；相邻文本段合并）
  static func splitInlineMath(_ text: String) -> [InlineSegment] {
    var segments: [InlineSegment] = []
    var current = ""
    var math = ""
    var inMath = false
    var previous: Character = " "
    for char in text {
      if char == "$", previous != "\\" {
        if inMath {
          segments.append(.math(math))
          math = ""
          inMath = false
        } else {
          if !current.isEmpty { segments.append(.text(current)) }
          current = ""
          inMath = true
        }
        previous = char
        continue
      }
      if inMath {
        math.append(char)
      } else {
        current.append(char)
      }
      previous = char
    }
    if inMath {
      current += "$" + math
    }
    if !current.isEmpty {
      segments.append(.text(current))
    }
    // 相邻文本段合并（未闭合 $ 回落产生的首尾两段实为一段）
    var merged: [InlineSegment] = []
    for segment in segments {
      if case .text(let string) = segment, case .text(let last)? = merged.last {
        merged[merged.count - 1] = .text(last + string)
      } else {
        merged.append(segment)
      }
    }
    return merged
  }
}

/// 块级公式视图：同步尺寸（出现即最终高度，滚动零跳变）；超宽外层横滑
struct SwiftMathBlockView: View {
  let source: String
  var fontSize: CGFloat = 15

  var body: some View {
    let measured = SwiftMathRenderer.measure(latex: source, fontSize: fontSize, displayMode: true)
    Group {
      if measured.width > 1, measured.height > 1 {
        GeometryReader { geometry in
          if measured.width > geometry.size.width {
            ScrollView(.horizontal) {
              SwiftMathLabel(latex: source, fontSize: fontSize, displayMode: true)
                .frame(width: measured.width, height: measured.height)
            }
          } else {
            SwiftMathLabel(latex: source, fontSize: fontSize, displayMode: true)
              .frame(width: measured.width, height: measured.height)
              .frame(maxWidth: .infinity)
          }
        }
        .frame(height: measured.height)
      } else {
        // 排版失败回落源码（SwiftMath 不支持的语法子集）
        Text("$$\(source)$$")
          .font(.system(size: 13, design: .monospaced))
          .textSelection(.enabled)
      }
    }
    .padding(.vertical, 2)
    .accessibilityLabel("数学公式")
  }
}

/// 行内混排公式：文本段走 markdown 行内样式渲染，公式段为 SwiftMath 位图内联
struct SwiftMathInlineText {
  /// 组装 Text：行内公式位图按基线偏移对齐（math axis ≈ 文本 x-height 中心）
  @MainActor
  static func makeText(_ text: String, fontSize: CGFloat = 14, inline: (String) -> AttributedString) -> Text {
    var result = Text("")
    for segment in SwiftMathRenderer.splitInlineMath(text) {
      switch segment {
      case .text(let string):
        result = result + Text(inline(string)).font(.system(size: fontSize))
      case .math(let latex):
        if let (image, size) = SwiftMathRenderer.image(latex: latex, fontSize: fontSize) {
          let offset = -(size.height - fontSize * 0.85) / 2
          result = result + Text(Image(nsImage: image)).baselineOffset(offset)
        } else {
          result = result + Text("$\(latex)$").font(.system(size: fontSize))
        }
      }
    }
    return result
  }
}

/// MTMathUILabel 包装（官方 README 的 NSViewRepresentable 口径）
private struct SwiftMathLabel: NSViewRepresentable {
  let latex: String
  let fontSize: CGFloat
  let displayMode: Bool

  func makeNSView(context: Context) -> MTMathUILabel {
    let label = MTMathUILabel()
    label.fontSize = fontSize
    label.labelMode = displayMode ? .display : .text
    label.textAlignment = .center
    label.latex = latex
    return label
  }

  func updateNSView(_ label: MTMathUILabel, context: Context) {
    if label.latex != latex {
      label.latex = latex
    }
  }
}
