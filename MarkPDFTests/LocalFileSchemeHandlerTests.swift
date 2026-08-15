import XCTest

@testable import MarkPDF

/// markpdf-file 协议路径围栏：仅允许根（工作区根/文档目录）内可读，
/// 工作区外绝对路径与 ../ 逃逸一律拒绝（纵深防御）
final class LocalFileSchemeHandlerTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SchemeHandlerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func testAllowsFileInsideRoot() {
    let root = dir.appendingPathComponent("ws")
    let file = root.appendingPathComponent("assets/pic.png")
    XCTAssertTrue(LocalFileSchemeHandler.isAllowed(file, roots: [root]))
    XCTAssertTrue(LocalFileSchemeHandler.isAllowed(root, roots: [root]), "根自身允许")
  }

  func testRejectsOutsideRootAndTraversal() {
    let root = dir.appendingPathComponent("ws")
    XCTAssertFalse(LocalFileSchemeHandler.isAllowed(dir.appendingPathComponent("other.png"), roots: [root]))
    // ../ 逃逸（标准化后落在根外）
    let escaped = root.appendingPathComponent("../outside.png")
    XCTAssertFalse(LocalFileSchemeHandler.isAllowed(escaped, roots: [root]))
    // 前缀相邻目录不算在内（/ws2 不是 /ws 的后代）
    XCTAssertFalse(LocalFileSchemeHandler.isAllowed(dir.appendingPathComponent("ws2/x.png"), roots: [root]))
  }

  func testNoRootsRejectsEverything() {
    XCTAssertFalse(LocalFileSchemeHandler.isAllowed(dir.appendingPathComponent("a.png"), roots: []))
  }

  func testSymlinkRootNormalized() throws {
    let real = dir.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = dir.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let fileViaLink = link.appendingPathComponent("pic.png")
    XCTAssertTrue(
      LocalFileSchemeHandler.isAllowed(fileViaLink, roots: [real]),
      "符号链接形态与真实路径同根")
  }
}
