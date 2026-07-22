import XCTest
@testable import MarkPDF

/// 拼音首字母（FR-6.3）：中文取拼音首字母、拉丁词取词首、混排
final class PinyinInitialsTests: XCTestCase {
  func testChinese() {
    XCTAssertEqual(PinyinInitials.of("中文"), "zw")
  }

  func testCommandTitle() {
    // 逐字取首字母：导d 出c 全q 部b 标b 注z 为w M
    XCTAssertEqual(PinyinInitials.of("导出全部标注为 Markdown"), "dcqbbzwm")
  }

  func testMixed() {
    XCTAssertEqual(PinyinInitials.of("新建文件夹"), "xjwjj")
  }

  func testEmpty() {
    XCTAssertEqual(PinyinInitials.of(""), "")
  }

  func testFuzzyMatchByPinyin() {
    // 命令面板核心场景：拼音首字母命中命令
    let pinyin = PinyinInitials.of("导出全部标注为 Markdown")
    XCTAssertNotNil(FuzzyMatcher.match(FuzzyMatcher.prepare("dc"), in: pinyin))
    XCTAssertNotNil(FuzzyMatcher.match(FuzzyMatcher.prepare("dcbz"), in: pinyin))
  }
}
