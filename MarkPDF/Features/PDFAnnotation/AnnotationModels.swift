import AppKit
import PDFKit

/// 标注类型（FR-4.1/4.3）
enum AnnotationKind: String, CaseIterable, Identifiable {
  /// 高亮
  case highlight
  /// 下划线
  case underline
  /// 删除线
  case strikeOut
  /// 批注（页边文本框 + 虚线连接器，FR-4.3 精简后唯一图形标注）
  case freeText

  var id: String { rawValue }

  var title: String {
    switch self {
    case .highlight: String(localized: "高亮")
    case .underline: String(localized: "下划线")
    case .strikeOut: String(localized: "删除线")
    case .freeText: String(localized: "批注")
    }
  }
}

/// 标注颜色（FR-4.4；对齐设计稿四色：黄 #FFD43B、绿 #94D82D、蓝 #74C0FC、红 #FF8787）
enum AnnotationColor: String, CaseIterable, Identifiable {
  case yellow
  case green
  case blue
  case red

  var id: String { rawValue }

  var nsColor: NSColor {
    switch self {
    case .yellow: NSColor(red: 1.0, green: 0.835, blue: 0.231, alpha: 1)
    case .green: NSColor(red: 0.580, green: 0.847, blue: 0.176, alpha: 1)
    case .blue: NSColor(red: 0.455, green: 0.780, blue: 0.988, alpha: 1)
    case .red: NSColor(red: 1.0, green: 0.529, blue: 0.529, alpha: 1)
    }
  }

  /// 各标注类型的默认用色（FR-4.4 记忆前的初始值）
  static func `default`(for kind: AnnotationKind) -> AnnotationColor {
    switch kind {
    case .highlight: .yellow
    case .underline: .blue
    case .strikeOut: .red
    case .freeText: .blue
    }
  }
}

extension AnnotationKind {
  /// 从 PDF 标注子类型映射（兼容 "Highlight" 与 "/Highlight" 两种上报形态）。
  /// 返回 nil 表示不在面板管理范围（Popup / 连接线 / 外部阅读器创建的其他类型）
  static func of(_ annotation: PDFAnnotation) -> AnnotationKind? {
    guard let raw = annotation.type else { return nil }
    let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    switch name {
    case "Highlight": return .highlight
    case "Underline": return .underline
    case "StrikeOut": return .strikeOut
    case "FreeText": return .freeText
    default: return nil
    }
  }
}

extension PDFAnnotation {
  /// 是否批注标记（/Text 便签图标；FR-4.3 批注在页边的锚点）。
  /// 注意 PDFKit 上报无前导斜杠（"Text"），两种形态都认
  var isCommentMarker: Bool {
    guard let type else { return false }
    return type == "Text" || type == PDFAnnotationSubtype.text.rawValue
  }
}

/// 是否本应用生成的标注组 ID。
/// 我们的组 ID 是 UUID；注意 PDFKit 会在创建标注时自动把系统用户名写进 userName，
/// 预览等第三方阅读器写的是作者名——这些都不能当组 ID（否则同作者标注会被并成一组）
func isAnnotationGroupID(_ userName: String?) -> Bool {
  guard let userName, !userName.isEmpty else { return false }
  return UUID(uuidString: userName) != nil
}

/// 标注列表条目（FR-4.5）：一次动作创建的同组标注合并为一项
struct AnnotationItem: Identifiable {
  /// 组 ID（无组单标注为对象标识）
  let id: String
  let annotations: [PDFAnnotation]
  let kind: AnnotationKind
  let color: NSColor
  /// 0 起页码
  let pageIndex: Int
  /// 覆盖文本摘录（可能为空）
  let excerpt: String
  /// 用户命名（标注 contents；空 = 未命名）
  let name: String

  var pageLabel: Int { pageIndex + 1 }
  /// 行主文案：改过名用名，否则用摘录
  var displayText: String {
    name.isEmpty ? excerpt : name
  }
}

/// 标注列表排序（FR-4.5：按页 / 颜色 / 类型）
enum AnnotationSort: String, CaseIterable, Identifiable {
  case page
  case color
  case type

  var id: String { rawValue }

  var title: String {
    switch self {
    case .page: String(localized: "按页码")
    case .color: String(localized: "按颜色")
    case .type: String(localized: "按类型")
    }
  }

  func sort(_ items: [AnnotationItem]) -> [AnnotationItem] {
    switch self {
    case .page:
      return items.sorted { a, b in
        if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
        // 页内按视觉顺序：页坐标 y 大者在上，再左到右
        let ay = a.annotations.first?.bounds.maxY ?? 0
        let by = b.annotations.first?.bounds.maxY ?? 0
        if ay != by { return ay > by }
        return (a.annotations.first?.bounds.minX ?? 0) < (b.annotations.first?.bounds.minX ?? 0)
      }
    case .color:
      return items.sorted { a, b in
        let ao = Self.colorOrder(a.color)
        let bo = Self.colorOrder(b.color)
        return ao != bo ? ao < bo : a.pageIndex < b.pageIndex
      }
    case .type:
      return items.sorted { a, b in
        let at = Self.typeOrder(a.kind)
        let bt = Self.typeOrder(b.kind)
        return at != bt ? at < bt : a.pageIndex < b.pageIndex
      }
    }
  }

  static func typeOrder(_ kind: AnnotationKind) -> Int {
    AnnotationKind.allCases.firstIndex(of: kind) ?? .max
  }

  /// 颜色排序键：与四色板最近者的色板序号
  static func colorOrder(_ color: NSColor) -> Int {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    var best = Int.max
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for (index, candidate) in AnnotationColor.allCases.enumerated() {
      let c = candidate.nsColor
      let dr = rgb.redComponent - c.redComponent
      let dg = rgb.greenComponent - c.greenComponent
      let db = rgb.blueComponent - c.blueComponent
      let distance = dr * dr + dg * dg + db * db
      if distance < bestDistance {
        bestDistance = distance
        best = index
      }
    }
    return best
  }
}
