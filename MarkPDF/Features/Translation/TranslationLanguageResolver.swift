import Foundation
import NaturalLanguage

/// 划词翻译语言解析（FR-AI.1）：检测源语言、按设置解析目标语言。
/// 纯逻辑无 UI，供 TranslationStore 与单测共用。
enum TranslationLanguageResolver {
  /// 检测源语言：限定在内置语种中取最优猜测（不设约束时识别失败会返回 nil，
  /// 系统翻译会因源语言不明弹出 Choose Language 选择窗——必须永远给出明确源语言）；
  /// 置信度不足（代码/术语等噪声文本会乱猜小语种）一律兜底英文（产品决策：不明即英译中）
  static func detectSource(_ text: String) -> AITargetLanguage {
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = [
      .simplifiedChinese, .traditionalChinese, .english, .japanese,
      .korean, .french, .german, .spanish, .russian,
    ]
    recognizer.processString(text)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
    guard let (dominant, confidence) = hypotheses.first, confidence >= 0.5 else { return .en }
    switch dominant {
    case .simplifiedChinese, .traditionalChinese: return .zh
    case .english: return .en
    case .japanese: return .ja
    case .korean: return .ko
    case .french: return .fr
    case .german: return .de
    case .spanish: return .es
    case .russian: return .ru
    default: return .en
    }
  }

  /// 解析目标语言：auto = 源中文→英文、其余（含未识别）→中文；
  /// 显式设定时直接用，源语言已是目标语言则返回 nil（无需翻译）
  static func resolveTarget(source: AITargetLanguage?, setting: AITargetLanguage) -> AITargetLanguage? {
    switch setting {
    case .auto:
      return source == .zh ? .en : .zh
    default:
      return setting == source ? nil : setting
    }
  }
}

extension AITargetLanguage {
  /// 系统翻译 TranslationSession 用的 Locale.Language（auto 无对应，须先 resolveTarget）
  var localeLanguage: Locale.Language {
    switch self {
    case .auto, .zh: Locale.Language(identifier: "zh-Hans")
    case .en: Locale.Language(identifier: "en")
    case .ja: Locale.Language(identifier: "ja")
    case .ko: Locale.Language(identifier: "ko")
    case .fr: Locale.Language(identifier: "fr")
    case .de: Locale.Language(identifier: "de")
    case .es: Locale.Language(identifier: "es")
    case .ru: Locale.Language(identifier: "ru")
    }
  }

  /// AI prompt 用的中文语言名
  var promptName: String {
    switch self {
    case .auto: "中文"
    case .zh: "中文"
    case .en: "英语"
    case .ja: "日语"
    case .ko: "韩语"
    case .fr: "法语"
    case .de: "德语"
    case .es: "西班牙语"
    case .ru: "俄语"
    }
  }
}
