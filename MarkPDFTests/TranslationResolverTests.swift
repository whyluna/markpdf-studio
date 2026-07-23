import XCTest
@testable import MarkPDF

/// 划词翻译语言解析（FR-AI.1）：源语言检测、目标语言解析、prompt 组装
final class TranslationResolverTests: XCTestCase {
  // MARK: - 源语言检测

  func testDetectChinese() {
    XCTAssertEqual(TranslationLanguageResolver.detectSource("这是一个用于测试的中文句子。"), .zh)
  }

  func testDetectEnglish() {
    XCTAssertEqual(
      TranslationLanguageResolver.detectSource("This is an English sentence for testing purposes."),
      .en
    )
  }

  func testDetectJapanese() {
    XCTAssertEqual(TranslationLanguageResolver.detectSource("これは日本語のテスト文章です。"), .ja)
  }

  func testDetectEmptyFallsBackEnglish() {
    XCTAssertEqual(TranslationLanguageResolver.detectSource(""), .en)
  }

  /// 代码/术语类文本识别不明时须给出明确猜测（系统翻译源语言不能为 nil，否则弹 Choose Language）
  func testDetectAmbiguousTerminologyStillGuesses() {
    XCTAssertEqual(TranslationLanguageResolver.detectSource("GEMM, cuBLAS"), .en)
  }

  // MARK: - 目标语言解析

  func testAutoChineseSourceGoesEnglish() {
    XCTAssertEqual(TranslationLanguageResolver.resolveTarget(source: .zh, setting: .auto), .en)
  }

  func testAutoNonChineseSourceGoesChinese() {
    XCTAssertEqual(TranslationLanguageResolver.resolveTarget(source: .en, setting: .auto), .zh)
    XCTAssertEqual(TranslationLanguageResolver.resolveTarget(source: .ja, setting: .auto), .zh)
  }

  func testAutoUnknownSourceGoesChinese() {
    XCTAssertEqual(TranslationLanguageResolver.resolveTarget(source: nil, setting: .auto), .zh)
  }

  func testExplicitTarget() {
    XCTAssertEqual(TranslationLanguageResolver.resolveTarget(source: .en, setting: .ja), .ja)
  }

  func testExplicitSameAsSourceMeansNoTranslation() {
    XCTAssertNil(TranslationLanguageResolver.resolveTarget(source: .zh, setting: .zh))
  }

  // MARK: - prompt 组装

  func testPromptContainsTargetAndText() {
    let prompt = TranslationPromptBuilder.userPrompt(text: "Hello world", target: .zh)
    XCTAssertTrue(prompt.contains("中文"))
    XCTAssertTrue(prompt.contains("Hello world"))
  }

  func testSystemMessageConstrainsOutput() {
    XCTAssertTrue(TranslationPromptBuilder.systemMessage.contains("只输出译文"))
  }

  // MARK: - Locale.Language 映射

  func testLocaleLanguageMapping() {
    XCTAssertEqual(AITargetLanguage.zh.localeLanguage, Locale.Language(identifier: "zh-Hans"))
    XCTAssertEqual(AITargetLanguage.en.localeLanguage, Locale.Language(identifier: "en"))
    XCTAssertEqual(AITargetLanguage.ru.localeLanguage, Locale.Language(identifier: "ru"))
  }
}
