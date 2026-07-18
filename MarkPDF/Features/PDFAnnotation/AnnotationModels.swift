import AppKit

/// 标注类型（FR-4.1/4.2/4.3）
enum AnnotationKind: String, CaseIterable, Identifiable {
  /// 高亮
  case highlight
  /// 下划线
  case underline
  /// 删除线
  case strikeOut
  /// 波浪线
  case squiggly
  /// 便签
  case note
  /// 文本框
  case freeText
  /// 手绘
  case ink
  /// 矩形
  case rectangle
  /// 箭头
  case arrow

  var id: String { rawValue }

  var title: String {
    switch self {
    case .highlight: "高亮"
    case .underline: "下划线"
    case .strikeOut: "删除线"
    case .squiggly: "波浪线"
    case .note: "便签"
    case .freeText: "文本框"
    case .ink: "手绘"
    case .rectangle: "矩形"
    case .arrow: "箭头"
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
    case .squiggly: .green
    case .note: .yellow
    case .freeText: .blue
    case .ink: .red
    case .rectangle: .green
    case .arrow: .red
    }
  }
}
