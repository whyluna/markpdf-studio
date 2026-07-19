import XCTest
@testable import MarkPDF

/// 图片相对路径与移动后链接重写（FR-2.5）
final class MarkdownImageLinkRewriterTests: XCTestCase {
  private let root = URL(fileURLWithPath: "/tmp/ws")

  func testRelativePathSameDir() {
    let dir = root
    let file = root.appendingPathComponent("assets/a.png")
    XCTAssertEqual(MarkdownImageLinkRewriter.relativePath(from: dir, to: file), "assets/a.png")
  }

  func testRelativePathFromSubDir() {
    let dir = root.appendingPathComponent("notes/deep")
    let file = root.appendingPathComponent("assets/a.png")
    XCTAssertEqual(MarkdownImageLinkRewriter.relativePath(from: dir, to: file), "../../assets/a.png")
  }

  func testRelativePathEncodesSpaces() {
    let dir = root
    let file = root.appendingPathComponent("assets/我的 图.png")
    XCTAssertEqual(MarkdownImageLinkRewriter.relativePath(from: dir, to: file), "assets/我的%20图.png")
  }

  func testRewriteUpdatesRelativeImageLinks() {
    let md = "# 笔记\n\n![](assets/a.png)\n\n![alt](assets/b.png \"标题\")\n"
    let oldDir = root
    let newDir = root.appendingPathComponent("sub")
    let rewritten = MarkdownImageLinkRewriter.rewrite(markdown: md, fromOldDir: oldDir, toNewDir: newDir)
    XCTAssertEqual(rewritten, "# 笔记\n\n![](../assets/a.png)\n\n![alt](../assets/b.png \"标题\")\n")
  }

  func testRewriteKeepsExternalAndAbsoluteLinks() {
    let md = "![](https://example.com/a.png)\n![](data:image/png;base64,xxxx)\n![](/abs/path.png)\n"
    let rewritten = MarkdownImageLinkRewriter.rewrite(
      markdown: md,
      fromOldDir: root,
      toNewDir: root.appendingPathComponent("sub")
    )
    XCTAssertEqual(rewritten, md)
  }

  func testRewriteDecodesPercentEncodedPaths() {
    let md = "![](assets/%E6%88%91%E7%9A%84%20%E5%9B%BE.png)\n"
    let rewritten = MarkdownImageLinkRewriter.rewrite(
      markdown: md,
      fromOldDir: root,
      toNewDir: root.appendingPathComponent("sub")
    )
    // 统一重写为 App 自身生成的形式（中文原样、空格 %20）
    XCTAssertEqual(rewritten, "![](../assets/我的%20图.png)\n")
  }

  func testRewriteDoesNotTouchPlainLinks() {
    let md = "[文本](assets/a.png)\n"
    let rewritten = MarkdownImageLinkRewriter.rewrite(
      markdown: md,
      fromOldDir: root,
      toNewDir: root.appendingPathComponent("sub")
    )
    XCTAssertEqual(rewritten, md)
  }
}

/// 图片资产存储（FR-2.5）：写 assets/、唯一命名、相对路径返回
final class ImageAssetServiceTests: XCTestCase {
  private var tempDir: URL!
  private let service = LiveImageAssetService()
  private let pngData = Data([0x89, 0x50, 0x4E, 0x47])

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageAssetServiceTests.\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  func testSaveCreatesAssetsDirAndFile() throws {
    let path = try service.save(
      data: pngData, suggestedName: nil, mime: "image/png",
      workspaceRoot: tempDir, documentDir: tempDir)
    XCTAssertTrue(path.hasPrefix("assets/pasted-"))
    XCTAssertTrue(path.hasSuffix(".png"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(path).path))
  }

  func testSaveUsesSuggestedName() throws {
    let path = try service.save(
      data: pngData, suggestedName: "截屏 2026.png", mime: "image/png",
      workspaceRoot: tempDir, documentDir: tempDir)
    XCTAssertEqual(path, "assets/截屏-2026.png")
  }

  func testSaveUniquifiesOnCollision() throws {
    let first = try service.save(
      data: pngData, suggestedName: nil, mime: "image/png",
      workspaceRoot: tempDir, documentDir: tempDir)
    let second = try service.save(
      data: pngData, suggestedName: nil, mime: "image/png",
      workspaceRoot: tempDir, documentDir: tempDir)
    XCTAssertNotEqual(first, second)
  }

  func testExtensionFromMime() {
    XCTAssertEqual(LiveImageAssetService.extensionFor(mime: "image/jpeg", suggestedName: nil), "jpg")
    XCTAssertEqual(LiveImageAssetService.extensionFor(mime: "image/svg+xml", suggestedName: nil), "svg")
    XCTAssertEqual(LiveImageAssetService.extensionFor(mime: nil, suggestedName: "a.webp"), "webp")
    XCTAssertEqual(LiveImageAssetService.extensionFor(mime: nil, suggestedName: nil), "png")
  }

  func testRelativePathFromSubDirectoryDocument() throws {
    let docDir = tempDir.appendingPathComponent("notes")
    try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
    let path = try service.save(
      data: pngData, suggestedName: nil, mime: "image/png",
      workspaceRoot: tempDir, documentDir: docDir)
    XCTAssertTrue(path.hasPrefix("../assets/pasted-"))
    XCTAssertTrue(path.hasSuffix(".png"))
  }
}
