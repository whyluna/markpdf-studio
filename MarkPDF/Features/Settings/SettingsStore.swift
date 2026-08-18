import AppKit
import Foundation
import PDFKit
import os

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
      case .system: String(localized: "系统默认")
      case .serif: String(localized: "衬线（宋体系）")
      case .mono: String(localized: "等宽")
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
      case .continuous: String(localized: "连续滚动")
      case .singlePage: String(localized: "单页")
      case .twoPages: String(localized: "双页连续")
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
  /// 段距（美化第二阶段）：块间空行行高系数，1.0 = GitHub 式紧凑节奏
  @Published var editorParaGap: Double {
    didSet { defaults.set(editorParaGap, forKey: Key.paraGap) }
  }
  @Published var pdfViewMode: PDFViewMode {
    didSet { defaults.set(pdfViewMode.rawValue, forKey: Key.pdfViewMode) }
  }

  /// 应用外观（全局明暗）：system 跟随系统；light/dark 经 NSApp.appearance
  /// 覆盖所有窗口（侧边栏/标签栏/检查器/MD 内核/PDF 均随 colorScheme 联动）
  enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
      switch self {
      case .system: String(localized: "跟随系统")
      case .light: String(localized: "浅色")
      case .dark: String(localized: "深色")
      }
    }
  }

  @Published var appAppearance: AppAppearance {
    didSet {
      defaults.set(appAppearance.rawValue, forKey: Key.appAppearance)
      applyAppAppearance()
    }
  }

  /// 写 NSApp.appearance：nil = 跟随系统；SwiftUI/AppKit 全部窗口立即换肤
  private func applyAppAppearance() {
    NSApp.appearance = switch appAppearance {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  /// PDF 阅读主题（FR-3.6；羊皮纸档经用户决策移除）。
  /// 不再独立存储——由全局外观推导（深色 → 夜间反色），
  /// PDF 视图经 colorScheme 环境实时联动，系统切换浅深色同样跟随
  enum PDFReadingTheme: String, CaseIterable, Identifiable {
    case day
    case night

    var id: String { rawValue }

    var title: String {
      switch self {
      case .day: String(localized: "白天")
      case .night: String(localized: "夜间")
      }
    }
  }
  /// 打字机模式（FR-2.10：当前行垂直居中）
  @Published var typewriterMode: Bool {
    didSet {
      defaults.set(typewriterMode, forKey: Key.typewriterMode)
      Logger.editor.debug("设置写入: typewriterMode=\(self.typewriterMode)")
    }
  }
  /// 专注模式（FR-2.10：高亮当前段落）
  @Published var focusMode: Bool {
    didSet {
      defaults.set(focusMode, forKey: Key.focusMode)
      Logger.editor.debug("设置写入: focusMode=\(self.focusMode)")
    }
  }

  /// 界面语言（重启后生效）：system 跟随 macOS；其余写 AppleLanguages 覆盖，
  /// 系统菜单（About/Settings/Quit 由运行时提供）与界面文案在下次启动统一切换
  enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    /// 语言名用自体（autonym），任何语言界面下都可辨认；仅「跟随系统」走本地化
    var title: String {
      switch self {
      case .system: String(localized: "跟随系统")
      case .zhHans: "中文"
      case .en: "English"
      }
    }
  }

  @Published var appLanguage: AppLanguage {
    didSet {
      defaults.set(appLanguage.rawValue, forKey: Key.appLanguage)
      // 只写不读回（cfprefsd 时序风险）；不 synchronize（废弃且不必要）
      if let value = Self.appleLanguagesValue(for: appLanguage) {
        defaults.set(value, forKey: "AppleLanguages")
      } else {
        defaults.removeObject(forKey: "AppleLanguages")
      }
    }
  }

  /// AppleLanguages 覆盖值（纯函数供单测）：nil = 移除覆盖、跟随系统
  nonisolated static func appleLanguagesValue(for language: AppLanguage) -> [String]? {
    switch language {
    case .system: nil
    case .zhHans: ["zh-Hans"]
    case .en: ["en"]
    }
  }

  /// 编辑器内核（JS）语言：从自有 key 推导（不读回 AppleLanguages）
  var effectiveWebLocale: String {
    Self.webLocale(for: appLanguage)
  }

  /// 启动期静态读取（NSViewRepresentable/静态初始化处无 store 实例；语言重启后生效，读一次即准）
  nonisolated static var launchWebLocale: String {
    let raw = UserDefaults.standard.string(forKey: Key.appLanguage) ?? ""
    return webLocale(for: AppLanguage(rawValue: raw) ?? .system)
  }

  /// 内核语言推导（internal 供 SettingsView 重启提示比对与单测）
  nonisolated static func webLocale(for language: AppLanguage) -> String {
    switch language {
    case .zhHans: "zh"
    case .en: "en"
    case .system:
      // 与系统菜单同一口径：按 bundle 本地化解析推导（zh-Hant 系统回退链
      // 落 zh-Hans 则给 zh，落 en 则给 en），不再用 preferredLanguages 猜前缀
      webLocale(forSystemLocalization: Bundle.preferredLocalizations(from: ["zh-Hans", "en"]).first)
    }
  }

  /// .system 分支推导（纯函数供单测）：本地化解析结果落 zh-Hans → zh，其余 → en
  nonisolated static func webLocale(forSystemLocalization resolved: String?) -> String {
    resolved == "zh-Hans" ? "zh" : "en"
  }

  private let defaults: UserDefaults
  private enum Key {
    static let font = "settings.editorFont"
    static let fontSize = "settings.editorFontSize"
    static let lineHeight = "settings.editorLineHeight"
    static let paraGap = "settings.editorParaGap"
    static let pdfViewMode = "settings.pdfViewMode"
    static let typewriterMode = "settings.typewriterMode"
    static let focusMode = "settings.focusMode"
    static let pdfReadingTheme = "settings.pdfReadingTheme" // 旧键：仅作迁移读取
    static let appAppearance = "settings.appAppearance"
    static let appLanguage = "settings.appLanguage"
  }

  /// 默认值（与内核 baseTheme 一致）
  static let defaultFontSize = 15.5
  static let defaultLineHeight = 1.8
  static let defaultParaGap = 1.0

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    editorFont = EditorFont(rawValue: defaults.string(forKey: Key.font) ?? "") ?? .system
    let fontSize = defaults.double(forKey: Key.fontSize)
    editorFontSize = fontSize > 0 ? fontSize : Self.defaultFontSize
    let lineHeight = defaults.double(forKey: Key.lineHeight)
    editorLineHeight = lineHeight > 0 ? lineHeight : Self.defaultLineHeight
    let paraGap = defaults.double(forKey: Key.paraGap)
    editorParaGap = paraGap > 0 ? paraGap : Self.defaultParaGap
    pdfViewMode = PDFViewMode(rawValue: defaults.string(forKey: Key.pdfViewMode) ?? "") ?? .continuous
    // 迁移：独立 PDF 阅读主题已并入全局外观——老用户存过「夜间」且没选过外观的，
    // 首次升级直接落深色，夜间阅读习惯不打断
    if defaults.string(forKey: Key.appAppearance) == nil,
      (defaults.string(forKey: Key.pdfReadingTheme) ?? "day") == "night"
    {
      appAppearance = .dark
      defaults.set(AppAppearance.dark.rawValue, forKey: Key.appAppearance)
    } else {
      appAppearance = AppAppearance(rawValue: defaults.string(forKey: Key.appAppearance) ?? "") ?? .system
    }
    typewriterMode = defaults.bool(forKey: Key.typewriterMode)
    focusMode = defaults.bool(forKey: Key.focusMode)
    appLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.appLanguage) ?? "") ?? .system
    // 存储属性全部就绪后再动 NSApp（didSet 不会在 init 阶段触发）
    applyAppAppearance()
  }
}
