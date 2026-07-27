import XCTest
@testable import MarkPDF

/// 划词分栏裁剪（双栏论文右栏划词不带左栏）与翻译源文本整理
final class SelectionColumnTrimmerTests: XCTestCase {
  /// 构造双栏行集：左栏 x 40–260、右栏 x 300–520，各 4 行
  private func twoColumnBounds() -> [CGRect] {
    var rects: [CGRect] = []
    for i in 0..<4 {
      rects.append(CGRect(x: 40, y: 100 - i * 20, width: 220, height: 12))
    }
    for i in 0..<4 {
      rects.append(CGRect(x: 300, y: 100 - i * 20, width: 220, height: 12))
    }
    return rects
  }

  func testDragWithinRightColumnKeepsOnlyRightColumnLines() {
    let bounds = twoColumnBounds()
    // 起止都在右栏（x≈400）
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 400, y: 95),
      dragEnd: NSPoint(x: 420, y: 30)
    )
    XCTAssertEqual(kept, [4, 5, 6, 7], "右栏拖拽只保留右栏 4 行")
  }

  func testDragWithinLeftColumnKeepsOnlyLeftColumnLines() {
    let bounds = twoColumnBounds()
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 100, y: 30),
      dragEnd: NSPoint(x: 60, y: 95)
    )
    XCTAssertEqual(kept, [0, 1, 2, 3])
  }

  func testCrossColumnDragKeepsEverything() {
    let bounds = twoColumnBounds()
    // 顺向跨栏（左栏→右栏，阅读顺序）：有意跨栏复制，保持原选区
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 100, y: 30),
      dragEnd: NSPoint(x: 400, y: 95)
    )
    XCTAssertEqual(kept, Array(bounds.indices))
  }

  func testBackwardCrossColumnDragKeepsEverything() {
    let bounds = twoColumnBounds()
    // 逆向跨栏（右栏→左栏）同样视为有意跨栏保持原选区：缩进/公式会聚成伪栏，
    // 「裁到起始栏」会让栏内向左回拖被误裁（该规则已回退，此为回归用例）
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 400, y: 95),
      dragEnd: NSPoint(x: 100, y: 30)
    )
    XCTAssertEqual(kept, Array(bounds.indices))
  }

  func testSingleColumnKeepsEverything() {
    let bounds = [CGRect(x: 40, y: 0, width: 200, height: 12),
      CGRect(x: 40, y: 20, width: 200, height: 12)]
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 100, y: 25),
      dragEnd: NSPoint(x: 100, y: 5)
    )
    XCTAssertEqual(kept, [0, 1])
  }

  func testEndpointOutsideColumnsKeepsEverything() {
    let bounds = twoColumnBounds()
    // 起点在栏间空白/图区（x 不落入任何栏）
    let kept = SelectionColumnTrimmer.keptLineIndices(
      lineBounds: bounds,
      dragStart: NSPoint(x: 278, y: 95),
      dragEnd: NSPoint(x: 400, y: 30)
    )
    XCTAssertEqual(kept, Array(bounds.indices))
  }

  // MARK: - 源文本整理

  func testNormalizerJoinsPhysicalLines() {
    XCTAssertEqual(
      TranslationTextNormalizer.normalize("the KV cache is managed is critical\nin determining\nthe maximum batch size"),
      "the KV cache is managed is critical in determining the maximum batch size"
    )
  }

  func testNormalizerDehyphenates() {
    XCTAssertEqual(
      TranslationTextNormalizer.normalize("informa-\ntion frag-\nmentation"),
      "information fragmentation"
    )
  }

  func testNormalizerCollapsesWhitespace() {
    XCTAssertEqual(
      TranslationTextNormalizer.normalize("  a  b \n\n c "),
      "a b c"
    )
  }

  func testNormalizerEmpty() {
    XCTAssertEqual(TranslationTextNormalizer.normalize(" \n "), "")
  }
}
