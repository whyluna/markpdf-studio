import XCTest
@testable import MarkPDF

/// 写提案纯逻辑（FR-AI.5）：S/R 块应用引擎 + 写路径解析
final class AIChangeModelsTests: XCTestCase {
  // MARK: - AIEditApplication

  private func edit(_ old: String, _ new: String) -> AIFileChange.TextEdit {
    AIFileChange.TextEdit(oldText: old, newText: new)
  }

  func testUniqueMatchReplaces() {
    let outcome = AIEditApplication.apply([edit("注意力", "记忆机制")], to: "注意力是关键")
    XCTAssertEqual(outcome.text, "记忆机制是关键")
    XCTAssertEqual(outcome.appliedIndices, [0])
    XCTAssertTrue(outcome.failures.isEmpty)
  }

  func testSequentialEditsApplyInOrder() {
    // 后一条的 oldText 命中前一条改写后的文本（顺序应用）
    let outcome = AIEditApplication.apply(
      [edit("# 初稿", "# 二稿"), edit("正文待改", "正文已改")],
      to: "# 初稿\n正文待改"
    )
    XCTAssertEqual(outcome.text, "# 二稿\n正文已改")
    XCTAssertEqual(outcome.appliedCount, 2)
  }

  func testSequentialEditDependsOnEarlierResult() {
    // 第二条的 oldText 只在第一条应用后才存在（链式改写）
    let outcome = AIEditApplication.apply(
      [edit("版本 A", "版本 B"), edit("版本 B", "版本 C")],
      to: "当前是版本 A"
    )
    XCTAssertEqual(outcome.text, "当前是版本 C")
    XCTAssertEqual(outcome.appliedCount, 2)
  }

  func testNotFoundRecordsFailureWithoutAborting() {
    let outcome = AIEditApplication.apply(
      [edit("不存在的段落", "X"), edit("存在", "Y")],
      to: "这里存在内容"
    )
    XCTAssertEqual(outcome.text, "这里Y内容")
    XCTAssertEqual(outcome.failures[0], .notFound)
    XCTAssertEqual(outcome.appliedIndices, [1])
  }

  func testAmbiguousFailsUnlessReplaceAll() {
    let text = "重复 重复"
    let ambiguous = AIEditApplication.apply([edit("重复", "X")], to: text)
    XCTAssertEqual(ambiguous.failures[0], .ambiguous(count: 2))
    XCTAssertEqual(ambiguous.text, text, "多义不落任何改动")

    let all = AIEditApplication.apply([edit("重复", "X")], to: text, replaceAll: true)
    XCTAssertEqual(all.text, "X X")
    XCTAssertEqual(all.appliedCount, 1)
  }

  func testEmptyOldTextFails() {
    let outcome = AIEditApplication.apply([edit("", "插入")], to: "abc")
    XCTAssertEqual(outcome.failures[0], .emptyOldText)
    XCTAssertEqual(outcome.text, "abc")
  }

  func testSkippingExcludesIndices() {
    let outcome = AIEditApplication.apply(
      [edit("A", "1"), edit("B", "2"), edit("C", "3")],
      to: "A B C",
      skipping: [1]
    )
    XCTAssertEqual(outcome.text, "1 B 3")
    XCTAssertEqual(outcome.appliedIndices, [0, 2])
    XCTAssertTrue(outcome.failures.isEmpty)
  }

  // MARK: - 写路径解析（AIToolRegistry.resolveWritePath）

  private let root = URL(fileURLWithPath: "/tmp/ws")

  private func resolve(
    _ path: String, ext: String? = "md"
  ) -> (url: URL, relative: String)? {
    AIToolRegistry.resolveWritePath(path, root: root, requireExtension: ext)
  }

  func testResolveValidNestedPath() {
    let resolved = resolve("笔记/子目录/读书笔记.md")
    XCTAssertEqual(resolved?.relative, "笔记/子目录/读书笔记.md")
    XCTAssertEqual(resolved?.url.path, "/tmp/ws/笔记/子目录/读书笔记.md")
  }

  func testResolveNormalizes() {
    XCTAssertEqual(resolve(" 笔记/a.md ")?.relative, "笔记/a.md")
    XCTAssertEqual(resolve("./笔记/a.md")?.relative, "笔记/a.md")
  }

  func testResolveRejectsEscape() {
    XCTAssertNil(resolve("../outside.md"), "相对逃逸")
    XCTAssertNil(resolve("/etc/passwd"), "绝对路径")
    XCTAssertNil(resolve("~/a.md"), "家目录")
    XCTAssertNil(resolve(""), "空路径")
    // 标准化后逃逸（root/../../x）
    XCTAssertNil(resolve("a/../../x.md"))
  }

  func testResolveRejectsExcludedAndHidden() {
    XCTAssertNil(resolve(".git/config.md"), "隐藏段")
    XCTAssertNil(resolve(".markpdf/sessions.md"), "App 自有数据目录")
    XCTAssertNil(resolve("node_modules/pkg/readme.md"), "排除目录")
    XCTAssertNil(resolve("笔记/.隐藏.md"), "隐藏文件名")
  }

  func testResolveEnforcesExtension() {
    XCTAssertNil(resolve("笔记.txt"), "非 md 文件")
    XCTAssertNotNil(resolve("笔记.MD"), "扩展名大小写不敏感")
    XCTAssertNotNil(resolve("附件目录", ext: nil), "文件夹不限制扩展名")
  }

  func testResolveRootItselfRejected() {
    XCTAssertNil(resolve(".", ext: nil), "根目录自身不可作为目标")
  }

  func testResolveRejectsWorkspaceSymlinkEscapingRoot() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIWriteFence-\(UUID().uuidString)")
    let workspace = base.appendingPathComponent("workspace")
    let outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: workspace.appendingPathComponent("linked"), withDestinationURL: outside)
    defer { try? FileManager.default.removeItem(at: base) }

    XCTAssertNil(
      AIToolRegistry.resolveWritePath("linked/escape.md", root: workspace, requireExtension: "md"),
      "工作区内指向外部的符号链接不得绕过写路径围栏")
  }
}
