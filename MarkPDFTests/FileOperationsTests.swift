import XCTest
@testable import MarkPDF

/// FR-1.2 文件操作服务单测：在临时目录中验证新建/重命名/移动/唯一命名。
final class FileOperationsTests: XCTestCase {
  private var dir: URL!
  private var ops: LiveFileOperations!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FileOperationsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    ops = LiveFileOperations()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  func testCreateFile() throws {
    let url = dir.appendingPathComponent("a.md")
    try ops.createFile(at: url)
    XCTAssertTrue(exists(url))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "")
  }

  func testCreateFileRejectsExisting() throws {
    let url = dir.appendingPathComponent("a.md")
    try ops.createFile(at: url)
    XCTAssertThrowsError(try ops.createFile(at: url)) { error in
      XCTAssertEqual(error as? FileOperationError, .alreadyExists("a.md"))
    }
  }

  func testCreateFolder() throws {
    let url = dir.appendingPathComponent("notes")
    try ops.createFolder(at: url)
    var isDir: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
    XCTAssertTrue(isDir.boolValue)
  }

  func testRename() throws {
    let url = dir.appendingPathComponent("old.md")
    try ops.createFile(at: url)
    let newURL = try ops.rename(at: url, to: "new.md")
    XCTAssertEqual(newURL.lastPathComponent, "new.md")
    XCTAssertFalse(exists(url))
    XCTAssertTrue(exists(newURL))
  }

  func testRenameRejectsInvalidName() throws {
    let url = dir.appendingPathComponent("a.md")
    try ops.createFile(at: url)
    XCTAssertThrowsError(try ops.rename(at: url, to: "x/y.md")) { error in
      guard case .invalidName = error as? FileOperationError else {
        return XCTFail("期望 invalidName，实际 \(error)")
      }
    }
    XCTAssertThrowsError(try ops.rename(at: url, to: "  "))
  }

  func testRenameRejectsExisting() throws {
    let a = dir.appendingPathComponent("a.md")
    let b = dir.appendingPathComponent("b.md")
    try ops.createFile(at: a)
    try ops.createFile(at: b)
    XCTAssertThrowsError(try ops.rename(at: a, to: "b.md"))
  }

  func testRenameSameNameIsNoop() throws {
    let url = dir.appendingPathComponent("a.md")
    try ops.createFile(at: url)
    XCTAssertEqual(try ops.rename(at: url, to: "a.md"), url)
  }

  func testMove() throws {
    let file = dir.appendingPathComponent("a.md")
    let folder = dir.appendingPathComponent("sub")
    try ops.createFile(at: file)
    try ops.createFolder(at: folder)
    let newURL = try ops.move(at: file, toFolder: folder)
    XCTAssertEqual(newURL, folder.appendingPathComponent("a.md"))
    XCTAssertTrue(exists(newURL))
  }

  func testUniqueFileURL() throws {
    let first = dir.appendingPathComponent("未命名.md")
    try ops.createFile(at: first)
    XCTAssertEqual(ops.uniqueFileURL(in: dir, baseName: "未命名", ext: "md").lastPathComponent, "未命名 2.md")
    try ops.createFile(at: dir.appendingPathComponent("未命名 2.md"))
    XCTAssertEqual(ops.uniqueFileURL(in: dir, baseName: "未命名", ext: "md").lastPathComponent, "未命名 3.md")
  }

  func testUniqueFolderURL() throws {
    try ops.createFolder(at: dir.appendingPathComponent("未命名文件夹"))
    XCTAssertEqual(ops.uniqueFolderURL(in: dir, baseName: "未命名文件夹").lastPathComponent, "未命名文件夹 2")
  }
}
