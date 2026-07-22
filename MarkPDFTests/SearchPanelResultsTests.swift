import XCTest
@testable import MarkPDF

/// 搜索面板（QuickOpen/CommandPalette）结果计算与光标钳制单测：
/// 同分 tiebreak 排序确定性、空结果集 selectedIndex 不为 -1
final class SearchPanelResultsTests: XCTestCase {
  private func node(_ path: String) -> FileNode {
    let url = URL(fileURLWithPath: path)
    return FileNode(id: url, name: url.lastPathComponent, kind: .markdown)
  }

  // MARK: - 同分 tiebreak

  /// 同分候选按路径升序，且与输入顺序无关（修：无 tiebreak 时输入过程中行序抖动）
  func testQuickOpenSameScoreTiebreaksByPath() {
    // "ab" 对 "ab-c.md"/"ab-d.md" 打分相同（词首 + 连续，同长度）
    let a = node("/ws/a/ab-c.md")
    let z = node("/ws/z/ab-d.md")
    let forward = QuickOpenView.computeResults(query: "ab", files: [a, z])
    let reversed = QuickOpenView.computeResults(query: "ab", files: [z, a])
    XCTAssertEqual(forward.map(\.id), [a.id, z.id], "同分应按路径升序")
    XCTAssertEqual(reversed.map(\.id), forward.map(\.id), "同分排序必须与输入顺序无关")
  }

  /// 命令面板同分按标题升序
  func testCommandPaletteSameScoreTiebreaksByTitle() {
    // "ab" 对 "abc"/"abd" 打分相同（词首 + 连续，同长度；拼音通道均为 "a" 不命中）
    let abc = AppCommand(id: "1", title: "abc", section: "s") {}
    let abd = AppCommand(id: "2", title: "abd", section: "s") {}
    let results = CommandPaletteView.computeResults(query: "ab", commands: [abd, abc])
    XCTAssertEqual(results.map(\.title), ["abc", "abd"], "同分应按标题升序")
  }

  // MARK: - 结果计算口径

  /// 空查询取候选前缀（原行为保持）
  func testQuickOpenEmptyQueryTakesPrefix() {
    let files = (1...60).map { node("/ws/f\($0).md") }
    XCTAssertEqual(QuickOpenView.computeResults(query: "", files: files).count, 50)
  }

  /// 模糊匹配按分降序（原行为保持）
  func testQuickOpenOrdersByScoreDescending() {
    let best = node("/ws/vllm.pdf")
    let weak = node("/ws/x-vllm-long-name.md")
    let results = QuickOpenView.computeResults(query: "vllm", files: [weak, best])
    XCTAssertEqual(results.map(\.id), [best.id, weak.id])
  }

  /// 命令面板过滤不可用命令（原行为保持）
  func testCommandPaletteFiltersDisabledCommands() {
    let off = AppCommand(id: "1", title: "abc", section: "s", isEnabled: { false }) {}
    let on = AppCommand(id: "2", title: "abd", section: "s") {}
    let results = CommandPaletteView.computeResults(query: "ab", commands: [off, on])
    XCTAssertEqual(results.map(\.title), ["abd"])
  }

  // MARK: - 光标钳制

  func testClampedSelectionIndex() {
    XCTAssertEqual(clampedSelectionIndex(1, count: 0), 0, "空结果集不得钳出 -1")
    XCTAssertEqual(clampedSelectionIndex(0, count: 0), 0)
    XCTAssertEqual(clampedSelectionIndex(5, count: 3), 2, "超出末位钳到末位")
    XCTAssertEqual(clampedSelectionIndex(2, count: 5), 2)
    XCTAssertEqual(clampedSelectionIndex(-1, count: 5), 0, "负值钳到 0")
  }
}
