import XCTest
@testable import MarkPDF

/// 行级 diff（FR-AI.6）：Myers 脚本、hunk 归组、按勾选拼接（git add -p 语义）
final class LineDiffTests: XCTestCase {
  /// 生成 1...n 的行文本，指定行号替换为自定义内容
  private func lines(_ n: Int, changing: [Int: String] = [:]) -> String {
    (1...n).map { changing[$0] ?? String($0) }.joined(separator: "\n")
  }

  func testIdenticalTextProducesNoHunks() {
    XCTAssertTrue(LineDiff.diff("a\nb\nc", "a\nb\nc").isEmpty)
  }

  func testSingleLineChange() {
    let hunks = LineDiff.diff("# 标题\n正文\n结尾", "# 改题\n正文\n结尾")
    XCTAssertEqual(hunks.count, 1)
    let hunk = hunks[0]
    XCTAssertEqual(hunk.oldStart, 1)
    XCTAssertEqual(hunk.oldCount, 3, "3 行全进上下文")
    XCTAssertEqual(hunk.newCount, 3)
    let removed = hunk.lines.filter { $0.kind == .removed }
    let added = hunk.lines.filter { $0.kind == .added }
    XCTAssertEqual(removed.map(\.text), ["# 标题"])
    XCTAssertEqual(added.map(\.text), ["# 改题"])
    XCTAssertEqual(removed.first?.oldNumber, 1)
    XCTAssertEqual(added.first?.newNumber, 1)
  }

  func testDistantChangesGroupIntoSeparateHunks() {
    let old = lines(20)
    let new = lines(20, changing: [2: "改2", 18: "改18"])
    let hunks = LineDiff.diff(old, new)
    XCTAssertEqual(hunks.count, 2, "相距远的变化各成一块（默认 context 3）")
    XCTAssertTrue(hunks[0].changeCount < hunks[0].lines.count, "含上下文行")
  }

  func testNearbyChangesMergeIntoOneHunk() {
    // 相邻行变化 + 上下文 3 → 合并
    let old = lines(10)
    let new = lines(10, changing: [3: "改3", 6: "改6"])
    let hunks = LineDiff.diff(old, new)
    XCTAssertEqual(hunks.count, 1)
  }

  func testPureAdditionAtEnd() {
    let old = "a\nb"
    let new = "a\nb\n新增一\n新增二"
    let hunks = LineDiff.diff(old, new)
    XCTAssertEqual(hunks.count, 1)
    XCTAssertTrue(hunks[0].lines.filter { $0.kind == .added }.count >= 2)
    // 拼接全接受 = 提案全文
    let applied = LineDiff.applying(hunks, accepted: Set(hunks.map(\.id)), to: old)
    XCTAssertEqual(applied, new)
  }

  func testSpliceAcceptAllEqualsNew() {
    let cases = [
      ("a\nb\nc", "a\nB\nc"),
      ("", "全新内容\n第二行"),
      ("整篇删除\n内容", ""),
      ("a\nb\nc\nd\ne\nf\ng\nh", "a\nX\nc\nd\ne\nf\ng\nY"),
      ("中文\n内容\n混合 English", "中文\n改写\n混合 English"),
      ("尾行无换行", "尾行无换行\n追加"),
    ]
    for (old, new) in cases {
      let hunks = LineDiff.diff(old, new)
      let applied = LineDiff.applying(hunks, accepted: Set(hunks.map(\.id)), to: old)
      XCTAssertEqual(applied, new, "old=\(old.debugDescription)")
    }
  }

  func testSpliceAcceptNoneEqualsOld() {
    let old = "a\nb\nc\nd\ne"
    let new = "a\nB\nZ\nd\nE"
    let hunks = LineDiff.diff(old, new)
    XCTAssertEqual(LineDiff.applying(hunks, accepted: [], to: old), old)
  }

  func testSpliceSelectivelyAppliesMiddleHunk() {
    // 两处相距远的变化；只接受第二块
    let old = lines(20)
    let new = lines(20, changing: [2: "改2", 18: "改18"])
    let hunks = LineDiff.diff(old, new)
    let second = hunks[1].id
    let applied = LineDiff.applying(hunks, accepted: [second], to: old)
    let expected = lines(20, changing: [18: "改18"])
    XCTAssertEqual(applied, expected, "只应用第二块，第一块保持原文")
  }

  func testHunkIdsStableAcrossRecomputation() {
    let old = "a\nb\nc"
    let new = "a\nB\nc"
    XCTAssertEqual(Set(LineDiff.diff(old, new).map(\.id)), Set(LineDiff.diff(old, new).map(\.id)))
  }

  func testSplitLinesEdges() {
    XCTAssertEqual(LineDiff.splitLines(""), [])
    XCTAssertEqual(LineDiff.splitLines("单行"), ["单行"])
    XCTAssertEqual(LineDiff.splitLines("a\nb\n"), ["a", "b"], "末尾换行不产生空尾行")
    XCTAssertEqual(LineDiff.splitLines("a\n\nb"), ["a", "", "b"], "空行保留")
  }

  func testEmojiAndCJKLines() {
    let old = "第一行 😀\n第二行"
    let new = "第一行 😀\n第 2 行 ✅"
    let hunks = LineDiff.diff(old, new)
    XCTAssertEqual(LineDiff.applying(hunks, accepted: Set(hunks.map(\.id)), to: old), new)
  }
}
