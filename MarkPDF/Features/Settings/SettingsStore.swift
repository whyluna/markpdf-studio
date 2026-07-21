import Foundation
import PDFKit

/// 应用设置（FR-7.2）：编辑器字体/字号/行高、PDF 默认视图模式；即时生效并持久化。
@MainActor
final class SettingsStore: ObservableObject {
  /// 编辑器字体
  enum EditorFont: String, CaseIterable, Identifiable {
    case system
    case serif
    case mono

    var id: String { rawValue }

    var title: String {
      switch self {
      case .system: "系统默认"
      case .serif: "衬线（宋体系）"
      case .mono: "等宽"
      }
    }

    /// 内核 CSS font-family 值（nil = 用内核默认栈）
    var cssFontStack: String? {
      switch self {
      case .system: nil
      case .serif: "'Songti SC', 'STSong', Georgia, serif"
      case .mono: "'SF Mono', Menlo, Consolas, monospace"
      }
    }
  }

  /// PDF 默认视图模式
  enum PDFViewMode: String, CaseIterable, Identifiable {
    case continuous
    case singlePage
    case twoPages

    var id: String { rawValue }

    var title: String {
      switch self {
      case .continuous: "连续滚动"
      case .singlePage: "单页"
      case .twoPages: "双页连续"
      }
    }

    var pdfDisplayMode: PDFDisplayMode {
      switch self {
      case .continuous: .singlePageContinuous
      case .singlePage: .singlePage
      case .twoPages: .twoUpContinuous
      }
    }
  }

  @Published var editorFont: EditorFont {
    didSet { defaults.set(editorFont.rawValue, forKey: Key.font) }
  }
  @Published var editorFontSize: Double {
    didSet { defaults.set(editorFontSize, forKey: Key.fontSize) }
  }
  @Published var editorLineHeight: Double {
    didSet { defaults.set(editorLineHeight, forKey: Key.lineHeight) }
  }
  @Published var pdfViewMode: PDFViewMode {
    didSet { defaults.set(pdfViewMode.rawValue, forKey: Key.pdfViewMode) }
  }
  /// PDF 阅读主题（FR-3.6）
  enum PDFReadingTheme: String, CaseIterable, Identifiable {
    case day
    case sepia
    case night

    var id: String { rawValue }

    var title: String {
      switch self {
      case .day: "白天"
      case .sepia: "羊皮纸"
      case .night: "夜间"
      }
    }
  }

  /// PDF 阅读主题（FR-3.6）
  @Published var pdfReadingTheme: PDFReadingTheme {
    didSet { defaults.set(pdfReadingTheme.rawValue, forKey: Key.pdfReadingTheme) }
  }
  /// 打字机模式（FR-2.10：当前行垂直居中）
  @Published var typewriterMode: Bool {
    didSet { defaults.set(typewriterMode, forKey: Key.typewriterMode) }
  }
  /// 专注模式（FR-2.10：高亮当前段落）
  @Published var focusMode: Bool {
    didSet { defaults.set(focusMode, forKey: Key.focusMode) }
  }

  private let defaults: UserDefaults
  private enum Key {
    static let font = "settings.editorFont"
    static let fontSize = "settings.editorFontSize"
    static let lineHeight = "settings.editorLineHeight"
    static let pdfViewMode = "settings.pdfViewMode"
    static let typewriterMode = "settings.typewriterMode"
    static let focusMode = "settings.focusMode"
    static let pdfReadingTheme = "settings.pdfReadingTheme"
  }

  /// 默认值（与内核 baseTheme 一致）
  static let defaultFontSize = 15.5
  static let defaultLineHeight = 1.8

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    editorFont = EditorFont(rawValue: defaults.string(forKey: Key.font) ?? "") ?? .system
    let fontSize = defaults.double(forKey: Key.fontSize)
    editorFontSize = fontSize > 0 ? fontSize : Self.defaultFontSize
    let lineHeight = defaults.double(forKey: Key.lineHeight)
    editorLineHeight = lineHeight > 0 ? lineHeight : Self.defaultLineHeight
    pdfViewMode = PDFViewMode(rawValue: defaults.string(forKey: Key.pdfViewMode) ?? "") ?? .continuous
    pdfReadingTheme = PDFReadingTheme(rawValue: defaults.string(forKey: Key.pdfReadingTheme) ?? "") ?? .day
    typewriterMode = defaults.bool(forKey: Key.typewriterMode)
    focusMode = defaults.bool(forKey: Key.focusMode)
  }
}
