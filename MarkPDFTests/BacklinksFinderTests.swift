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

  func testIgnoresExternalAndUnrelatedLinks() {
    let md = write(
      "notes/d.md",
      "[官网](https://example.com/论文.pdf)\n[别的](other.pdf)\n[不存在](../papers/不存在.pdf)\n")
    let found = BacklinksFinder.find(target: target, in: [md], workspaceRoot: root)
    XCTAssertTrue(found.isEmpty)
  }

  func testEmptyLinkTextFallsBackToFileName() {
    let md = write("notes/e.md", "[](../papers/论文.pdf)\n")
    let found = BacklinksFinder.find(target: target, in: [md], workspaceRoot: root)
    XCTAssertEqual(found.first?.text, "e.md")
  }
}
