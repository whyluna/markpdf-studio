import XCTest
@testable import MarkPDF

/// 批次四：WorkspaceExcludedDirectories 名单扩充（Pods/Carthage/.venv/__pycache__/
/// target/dist/build/.next/vendor）与大小写不敏感判定的回归（FileWatcherFilterTests 不动，另起本文件）。
final class FileWatcherExcludeExtraTests: XCTestCase {
  private let root = "/workspace/proj"

  func testNewlyAddedDirectoriesAreFiltered() {
    let cases = [
      "/workspace/proj/Pods/AFNetworking/a.m",
      "/workspace/proj/Carthage/Build/iOS/Alamofire.framework/x",
      "/workspace/proj/.venv/lib/python3.12/site-packages/p.py",
      "/workspace/proj/__pycache__/mod.cpython-312.pyc",
      "/workspace/proj/target/debug/build/o.rs",
      "/workspace/proj/dist/bundle.js",
      "/workspace/proj/build/Release/app",
      "/workspace/proj/.next/static/chunks/main.js",
      "/workspace/proj/vendor/github.com/x/y.go",
    ]
    for path in cases {
      XCTAssertTrue(
        WorkspaceExcludedDirectories.isExcluded(eventPath: path, watchedRoot: root),
        "应被过滤：\(path)"
      )
    }
  }

  func testMatchingIsCaseInsensitive() {
    // 大小写变体同样拦截（Node_Modules、PODS、DerivedData 小写形态）
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/Node_Modules/pkg/index.js", watchedRoot: root))
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/PODS/AFNetworking/a.m", watchedRoot: root))
    XCTAssertTrue(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/deriveddata/proj/Build/x", watchedRoot: root))
  }

  func testSimilarNamesStillNotFiltered() {
    // 分段精确匹配不因扩充误伤：dist-build、builder、vendorx 均不在名单
    XCTAssertFalse(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/dist-build/a.js", watchedRoot: root))
    XCTAssertFalse(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/builder/a.js", watchedRoot: root))
    XCTAssertFalse(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/vendorx/a.go", watchedRoot: root))
    // 普通源码目录 src 不受影响
    XCTAssertFalse(WorkspaceExcludedDirectories.isExcluded(
      eventPath: "/workspace/proj/src/main.swift", watchedRoot: root))
  }

  /// names 保持原始大小写（WorkspaceStore 扫描的 lastPathComponent 精确匹配语义不变）
  func testSharedListKeepsCanonicalCasing() {
    for name in ["Pods", "Carthage", ".venv", "__pycache__", "target", "dist", "build", ".next", "vendor"] {
      XCTAssertTrue(WorkspaceExcludedDirectories.names.contains(name), "名单缺少 \(name)")
    }
    XCTAssertTrue(WorkspaceExcludedDirectories.names.contains("DerivedData"))
  }
}
