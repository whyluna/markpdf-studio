import XCTest
@testable import MarkPDF

/// Finder 直接打开文件的路由（决策纯函数 / 就绪队列 / 会话级拒绝记忆）
final class ExternalOpenCoordinatorTests: XCTestCase {
  // MARK: - 决策纯函数

  func testDecideSameRootOpensInWorkspace() {
    XCTAssertEqual(
      ExternalOpenCoordinator.decide(
        folderKey: "/Users/a/papers", currentRootPath: "/Users/a/papers", declinedFolders: []),
      .openInCurrentWorkspace
    )
  }

  func testDecideForeignFolderAsks() {
    XCTAssertEqual(
      ExternalOpenCoordinator.decide(
        folderKey: "/Users/a/papers", currentRootPath: "/Users/a/notes", declinedFolders: []),
      .openBareAndAsk
    )
  }

  func testDecideNoWorkspaceAsks() {
    XCTAssertEqual(
      ExternalOpenCoordinator.decide(
        folderKey: "/Users/a/papers", currentRootPath: nil, declinedFolders: []),
      .openBareAndAsk
    )
  }

  func testDecideDeclinedFolderSilent() {
    XCTAssertEqual(
      ExternalOpenCoordinator.decide(
        folderKey: "/Users/a/papers", currentRootPath: nil, declinedFolders: ["/Users/a/papers"]),
      .openBareSilent
    )
  }

  // MARK: - 就绪队列

  @MainActor
  func testURLsQueueUntilReady() {
    let coordinator = ExternalOpenCoordinator()
    var opened: [URL] = []
    coordinator.openFileTab = { opened.append($0) }
    // 同根路径：路由不弹窗（决策为 openInCurrentWorkspace）
    coordinator.currentRootPath = { "/tmp/ws" }

    let file = URL(fileURLWithPath: "/tmp/ws/a.pdf")
    coordinator.handle(file)
    XCTAssertTrue(opened.isEmpty, "未就绪时不路由")

    coordinator.markReady()
    XCTAssertEqual(opened, [file], "就绪后放行队列")

    let second = URL(fileURLWithPath: "/tmp/ws/b.pdf")
    coordinator.handle(second)
    XCTAssertEqual(opened, [file, second], "就绪后直接路由")
  }
}
