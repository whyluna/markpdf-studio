import XCTest
@testable import MarkPDF

/// FileWatcher 事件路径过滤（保存风暴修复）：排除目录子树内的事件不再触发全量重扫。
/// 单测纯判定函数 WorkspaceExcludedDirectories.isExcluded（FSEvents 回调本体由真机覆盖）。
final class FileWatcherFilterTests: XCTestCase {
  private let root = "/workspace/proj"

  func testEventInsideNodeModulesIsFiltered() {
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/node_modules/pkg/index.js", watchedRoot: root))
  }

  func testEventInsideNestedGitIsFiltered() {
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/.git/objects/ab/cdef", watchedRoot: root))
  }

  func testEventInDeepExcludedDirIsFiltered() {
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/packages/app/node_modules/dep/index.js", watchedRoot: root))
  }

  func testNormalFileEventPasses() {
    XCTAssertFalse(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/notes/a.md", watchedRoot: root))
  }

  func testRootItselfEventPasses() {
    // 根目录自身的变更（如权限/重命名）不过滤
    XCTAssertFalse(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj", watchedRoot: root))
  }

  func testSimilarPrefixNameIsNotFiltered() {
    // 分段精确匹配："node_modules_backup" 不是 "node_modules"
    XCTAssertFalse(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/node_modules_backup/a.js", watchedRoot: root))
  }

  func testRootInsideExcludedDirStillWatched() {
    // 用户直接打开排除目录下的项目：根路径恰含同名目录不影响监听（与扫描 depth>0 口径一致）
    let oddRoot = "/Users/x/DerivedData/proj"
    XCTAssertFalse(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/Users/x/DerivedData/proj/notes/a.md", watchedRoot: oddRoot))
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/Users/x/DerivedData/proj/node_modules/dep/index.js", watchedRoot: oddRoot))
  }

  func testWatchedRootWithTrailingSlash() {
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/.build/debug/app", watchedRoot: "/workspace/proj/"))
  }

  /// 与 WorkspaceStore 扫描共用同一份名单（防漂移回归）
  func testSharedListContainsKnownDirectories() {
    XCTAssertTrue(WorkspaceExcludedDirectories.names.contains("node_modules"))
    XCTAssertTrue(WorkspaceExcludedDirectories.names.contains(".git"))
    XCTAssertTrue(WorkspaceExcludedDirectories.names.contains("DerivedData"))
  }
}
