import Foundation

/// 划词翻译的 AI prompt 组装（FR-AI.1）：约束模型只输出译文
enum TranslationPromptBuilder {
  static let systemMessage = "你是一台翻译引擎。只输出译文，不要解释、不要加引号、不要重复原文。"

  static func userPrompt(text: String, target: AITargetLanguage) -> String {
    "把下面的文本翻译成\(target.promptName)：\n\n\(text)"
  }
}
