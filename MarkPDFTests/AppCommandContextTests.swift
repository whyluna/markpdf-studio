import XCTest
@testable import MarkPDF

/// 菜单命令上下文（v1.5 多窗口）：Equatable 只比状态标志，闭包不参与
final class AppCommandContextTests: XCTestCase {
  func testEqualityComparesFlagsOnly() {
    var lhs = AppCommandContext()
    var rhs = AppCommandContext()
    // 闭包不同不影响相等（菜单刷新只关心标志位）
    lhs.save = { XCTFail("不应调用") }
    rhs.zoomIn = { XCTFail("不应调用") }
    XCTAssertEqual(lhs, rhs)

    rhs.isPDF = true
    XCTAssertNotEqual(lhs, rhs, "标志位变化必须触发不等（菜单禁用态刷新依据）")
  }

  func testEachFlagParticipatesInEquality() {
    let base = AppCommandContext()
    let mutations: [(inout AppCommandContext) -> Void] = [
      { $0.zoomable = true },
      { $0.isPDF = true },
      { $0.hasEditor = true },
      { $0.canExportAnnotations = true },
      { $0.hasPDFSelection = true },
      { $0.isFindBarVisible = true },
      { $0.isSidecarMode = true },
      { $0.sidecarAvailable = true },
      { $0.isAIVisible = true },
    ]
    for (index, mutate) in mutations.enumerated() {
      var changed = AppCommandContext()
      mutate(&changed)
      XCTAssertNotEqual(base, changed, "第 \(index) 个标志未参与 Equatable")
    }
  }
}
