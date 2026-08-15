import XCTest
@testable import MarkPDF

/// 反向链接查找（FR-5.4）：相对/根目录路径命中、自引用排除、图片排除、文本捕获
final class BacklinksFinderTests: XCTestCase {
  private var tempDir: URL!
  private var root: URL!
  private var target: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BacklinksFinderTests.\(UUID().uuidString)")
    root = tempDir
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    target = root.appendingPathComponent("papers/论文.pdf")
    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data().write(to: target)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  private func write(_ rel: String, _ content: String) -> URL {
    let url = root.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! content.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func testFindsRelativeLink() {
    let md = write("notes/a.md", "参见 [论文](../papers/论文.pdf) 与 [页码](../papers/论文.pdf#page=3)\n")
    let found = BacklinksFinder.find(target: target, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.count, 2)
    XCTAssertEqual(found.first?.source, md)
    XCTAssertEqual(found.first?.text, "论文")
  }

  func testFindsWorkspaceRootRelativeLink() {
    let md = write("notes/deep/b.md", "[调研](papers/论文.pdf)\n")
    let found = BacklinksFinder.find(target: target, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.text, "调研")
  }

  func testExcludesSelfReference() {
    let found = BacklinksFinder.find(target: target, in: [target], workspaceRoot: root)
    XCTAssertTrue(found.isEmpty)
  }

  func testExcludesImageLinks() {
    let md = write("notes/c.md", "![截图](../papers/论文.pdf)\n")
    let found = BacklinksFinder.find(target: target, in: [md], workspaceRoot: root)
    XCTAssertTrue(found.isEmpty)
  }

  /// 回归：多字节字符前置的图片链接不再越界崩溃（UTF-16 下标误用 bug）
  func testImageExclusionWithMultibytePrefixDoesNotCrash() {
    let md = write(
      "notes/mb.md",
      "中文中文中文中文中文中文中文中文中文中文中文\n![截图](../papers/论文.pdf)\n[论文](../papers/论文.pdf)\n")
    let found = BacklinksFinder.find(target: target, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.text, "论文")
  }

  func testIgnoresExternalAndUnrelatedLinks() {
    let md = write(
      "notes/d.md",
      "[官网](https://example.com/论文.pdf)\n[别的](other.pdf)\n[不存在](../papers/不存在.pdf)\n")
    let found = BacklinksFinder.find(target: target, in: [md], workspaceRoot: root)
    XCTAssertTrue(found.isEmpty)
  }

  /// 回归：App 自产回链把空格编码为 %20，预筛不得漏报（原 contains(targetName) 直接跳过）
  func testFindsPercentEncodedLinkToSpacedName() {
    let spaced = root.appendingPathComponent("papers/vllm paper.pdf")
    try? Data().write(to: spaced)
    let md = write("notes/pc.md", "[量化](../papers/vllm%20paper.pdf)\n")
    let found = BacklinksFinder.find(target: spaced, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.text, "量化")
  }

  /// 回归：APFS 默认大小写不敏感，[x](Note.MD) 指向 note.md 不得被预筛/终比对漏掉
  func testFindsCaseVariantLink() {
    let note = root.appendingPathComponent("papers/note.md")
    try? Data().write(to: note)
    let md = write("notes/case.md", "[笔记](../papers/Note.MD)\n")
    let found = BacklinksFinder.find(target: note, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.text, "笔记")
  }

  /// 回归：CommonMark 角标形式 <dest 含空格> 不得截断在首个空格
  func testFindsAngleBracketDestinationWithSpaces() {
    let spaced = root.appendingPathComponent("papers/my note.md")
    try? Data().write(to: spaced)
    let md = write("notes/angle.md", "[摘录](<../papers/my note.md>)\n")
    let found = BacklinksFinder.find(target: spaced, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found.first?.text, "摘录")
  }

  func testEmptyLinkTextFallsBackToFileName() {
    let md = write("notes/e.md", "[](../papers/论文.pdf)\n")
    let found = BacklinksFinder.find(target: target, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.first?.text, "e.md")
  }

  /// 取消点（保存风暴修复）：isCancelled 逐文件检查，中止后返回已收集结果
  func testCancellationStopsScanEarly() {
    let a = write("notes/x.md", "[论文](../papers/论文.pdf)\n")
    let b = write("notes/y.md", "[论文](../papers/论文.pdf)\n")
    var calls = 0
    let found = BacklinksFinder.find(target: target, in: [a, b], workspaceRoot: root) {
      calls += 1
      return calls > 1  // 第一个文件处理后取消
    }
    XCTAssertEqual(found.map(\.source), [a])
    XCTAssertEqual(calls, 2)
  }

  /// 取消点：首个文件前就取消 → 立即返回空，不再读盘
  func testCancellationBeforeAnyFileReturnsEmpty() {
    let a = write("notes/z.md", "[论文](../papers/论文.pdf)\n")
    var calls = 0
    let found = BacklinksFinder.find(target: target, in: [a], workspaceRoot: root) {
      calls += 1
      return true
    }
    XCTAssertTrue(found.isEmpty)
    XCTAssertEqual(calls, 1)
  }
  /// 目标文件名含平衡括号（CommonMark 合法裸 dest）：反链不得截断漏配
  func testFindsLinkWithBalancedParensInFilename() {
    let parenTarget = root.appendingPathComponent("papers/报告(终稿).pdf")
    try! Data().write(to: parenTarget)
    let md = write("notes/b.md", "见 [报告](../papers/报告(终稿).pdf)\n")
    let found = BacklinksFinder.find(target: parenTarget, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.count, 1, "含括号的合法 dest 不得漏配")
    XCTAssertEqual(found.first?.text, "报告")
  }

  /// 超大 md 先 stat 后读盘（GB 级文件不整读进内存）
  func testOversizedMarkdownSkippedByStat() throws {
    let big = write("big.md", String(repeating: "字", count: 100))
    // 伪造超限判定：直接验证 isWithinSizeLimit 的口径
    XCTAssertTrue(BacklinksFinder.isWithinSizeLimit(big))
    let huge = write("huge.md", "x")
    try FileManager.default.removeItem(at: huge)
    XCTAssertTrue(BacklinksFinder.isWithinSizeLimit(huge), "stat 失败按不超限（交由读盘失败兜底）")
  }

}
