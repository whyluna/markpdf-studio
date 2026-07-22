import XCTest
@testable import MarkPDF

/// WorkspaceStore 撤销链回归测试（Bug A1/A2）：
/// 真实 FileOperations + 空 Watcher，UndoManager 驱动撤销/重做。
final class WorkspaceStoreTests: XCTestCase {
  private var dir: URL!
  private var ops: LiveFileOperations!
  private var store: WorkspaceStore!
  private var undo: UndoManager!
  /// onFileMoved 收到的 (oldURL, newURL) 序列
  private var moved: [(URL, URL)] = []

  /// 不做任何监听的 FileWatcher（测试无需外部变更重扫）
  private final class NoopWatcher: FileWatcher {
    func startWatching(url: URL, onChange: @escaping () -> Void) {}
    func stopWatching() {}
  }

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkspaceStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    ops = LiveFileOperations()
    store = WorkspaceStore(ops: ops, watcher: NoopWatcher())
    undo = UndoManager()
    moved = []
    store.onFileMoved = { [weak self] oldURL, newURL in
      self?.moved.append((oldURL, newURL))
    }
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func node(_ url: URL, kind: FileNode.Kind = .markdown) -> FileNode {
    FileNode(id: url, name: url.lastPathComponent, kind: kind)
  }

  /// Bug A1 回归：重命名的撤销/重做同样要通知标签层，方向随链条往返
  func testRenameNotifiesOnFileMovedAcrossUndoRedo() throws {
    let a = dir.appendingPathComponent("a.md")
    try ops.createFile(at: a)
    let b = try XCTUnwrap(store.rename(node(a), to: "b.md", undo: undo))
    XCTAssertEqual(moved.map(\.0), [a])
    XCTAssertEqual(moved.map(\.1), [b])

    undo.undo()
    XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    XCTAssertEqual(moved.map(\.0), [a, b])
    XCTAssertEqual(moved.map(\.1), [b, a])

    undo.redo()
    XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    XCTAssertEqual(moved.map(\.0), [a, b, a])
    XCTAssertEqual(moved.map(\.1), [b, a, b])
  }

  /// Bug A1 回归：移动同理（Store 内闭环的撤销链不得丢失通知）
  func testMoveNotifiesOnFileMovedAcrossUndoRedo() throws {
    let file = dir.appendingPathComponent("a.md")
    let sub = dir.appendingPathComponent("sub")
    try ops.createFile(at: file)
    try ops.createFolder(at: sub)
    let target = sub.appendingPathComponent("a.md")
    let newURL = try XCTUnwrap(store.move(node(file), toFolder: sub, undo: undo))
    XCTAssertEqual(newURL, target)
    XCTAssertEqual(moved.map(\.0), [file])
    XCTAssertEqual(moved.map(\.1), [target])

    undo.undo()
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(moved.map(\.0), [file, target])
    XCTAssertEqual(moved.map(\.1), [target, file])

    undo.redo()
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    XCTAssertEqual(moved.map(\.0), [file, target, file])
    XCTAssertEqual(moved.map(\.1), [target, file, target])
  }

  /// Bug A2 回归：撤销新建文件夹后重做，必须重建为文件夹而非空文件
  func testUndoCreateFolderRedoRecreatesFolder() throws {
    let folder = try XCTUnwrap(store.createFolder(in: dir, undo: undo))
    undo.undo()
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    undo.redo()
    var isDir: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir))
    XCTAssertTrue(isDir.boolValue, "重做的应是文件夹，实际建成了文件")
  }

  /// Bug A2 回归对照：新建文件的撤销/重做仍重建为文件
  func testUndoCreateMarkdownRedoRecreatesFile() throws {
    let file = try XCTUnwrap(store.createMarkdown(in: dir, undo: undo))
    undo.undo()
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    undo.redo()
    var isDir: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir))
    XCTAssertFalse(isDir.boolValue)
  }
}
