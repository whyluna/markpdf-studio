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

  // MARK: - FR-7.4 审查修复：子目录同根判定

  func testDecideSubdirectoryOfRootOpensInWorkspace() {
    XCTAssertEqual(
      ExternalOpenCoordinator.decide(
        folderKey: "/Users/a/notes/sub", currentRootPath: "/Users/a/notes", declinedFolders: []),
      .openInCurrentWorkspace,
      "工作区子目录的文件不得误判为异根（确认后会把工作区收窄到子目录）"
    )
  }

  func testDecideCommonPrefixSiblingStillAsks() {
    XCTAssertEqual(
      ExternalOpenCoordinator.decide(
        folderKey: "/Users/a/notes2", currentRootPath: "/Users/a/notes", declinedFolders: []),
      .openBareAndAsk,
      "路径组件边界：/a/b2 不是 /a/b 的后代"
    )
  }

  /// 工作区内判定（三处共用：decide / saveImage / tabsDidChange）
  func testIsWithinWorkspace() {
    let root = URL(fileURLWithPath: "/Users/a/notes")
    XCTAssertTrue(URL(fileURLWithPath: "/Users/a/notes").isWithinWorkspace(root: root), "根本身")
    XCTAssertTrue(
      URL(fileURLWithPath: "/Users/a/notes/sub/b.md").isWithinWorkspace(root: root), "根的后代")
    XCTAssertFalse(
      URL(fileURLWithPath: "/Users/a/notes2/b.md").isWithinWorkspace(root: root), "同前缀兄弟目录不算后代")
    XCTAssertFalse(URL(fileURLWithPath: "/Users/a/other").isWithinWorkspace(root: root))
  }

  // MARK: - 多窗口判定（v1.5）

  func testDecideAnyWindowWorkspaceContainingFolderOpensThere() {
    XCTAssertEqual(
      ExternalOpenCoordinator.decide(
        folderKey: "/Users/a/papers/sub",
        rootPaths: ["/Users/a/notes", "/Users/a/papers"],
        declinedFolders: []
      ),
      .openInCurrentWorkspace,
      "任一窗口的工作区包含该文件夹即在该窗口打开，不再弹询问"
    )
    XCTAssertEqual(
      ExternalOpenCoordinator.decide(
        folderKey: "/Users/a/loose",
        rootPaths: ["/Users/a/notes", "/Users/a/papers"],
        declinedFolders: []
      ),
      .openBareAndAsk,
      "所有窗口都不含 → 新开单文件窗口并询问"
    )
  }

  func testShouldPresentAskSkipsWhenAnyWindowSwitchedIn() {
    XCTAssertFalse(
      ExternalOpenCoordinator.shouldPresentAsk(
        folderKey: "/Users/a/papers",
        rootPaths: ["/Users/a/notes", "/Users/a/papers"],
        declinedFolders: []
      ),
      "排队期间某窗口已切进该文件夹：无需再问"
    )
  }

  // MARK: - FR-7.4 审查修复：类型白名单

  func testShouldHandleWhitelist() {
    XCTAssertTrue(
      ExternalOpenCoordinator.shouldHandle(URL(fileURLWithPath: "/a/b.md"), isDirectory: false))
    XCTAssertTrue(
      ExternalOpenCoordinator.shouldHandle(URL(fileURLWithPath: "/a/b.pdf"), isDirectory: false))
    XCTAssertTrue(
      ExternalOpenCoordinator.shouldHandle(URL(fileURLWithPath: "/a/b.png"), isDirectory: false))
    XCTAssertFalse(
      ExternalOpenCoordinator.shouldHandle(URL(fileURLWithPath: "/a/b.txt"), isDirectory: false),
      "白名单外类型直接忽略")
    XCTAssertFalse(
      ExternalOpenCoordinator.shouldHandle(URL(fileURLWithPath: "/a/b"), isDirectory: true),
      "目录直接忽略")
  }

  // MARK: - FR-7.4 审查修复：ask 流程串行化

  /// runModal 期间（嵌套事件循环）到达的 URL 只入队：弹窗不叠加，处理完依次放行；
  /// 文件本身仍先立即开标签
  @MainActor
  func testAsksAreSerializedDuringModal() {
    let coordinator = ExternalOpenCoordinator()
    coordinator.currentRootPath = { "/ws" }
    var opened: [URL] = []
    var events: [String] = []
    coordinator.openFileTab = { opened.append($0) }
    let a = URL(fileURLWithPath: "/other1/a.md")
    let b = URL(fileURLWithPath: "/other2/b.md")
    // 替换弹窗执行体避免 runModal；第一个 ask「弹窗期间」嵌套到达第二个文件
    coordinator.presentAsk = { folder, _, _ in
      events.append("start:\(folder.path)")
      if folder.path == "/other1" {
        coordinator.handle(b)
      }
      events.append("end:\(folder.path)")
    }
    coordinator.markReady()

    coordinator.handle(a)

    XCTAssertEqual(opened, [a, b], "三种决策都先立即开标签，嵌套到达的也一样")
    XCTAssertEqual(
      events,
      ["start:/other1", "end:/other1", "start:/other2", "end:/other2"],
      "第二个 ask 必须等第一个处理完才弹出，不得嵌套叠加")
  }

  /// 排队中的 ask 轮到放行时的跳过判定（纯函数）：已拒绝 / 已切入该文件夹的不再弹
  func testShouldPresentAskSkipsDeclinedOrSwitchedFolder() {
    XCTAssertFalse(
      ExternalOpenCoordinator.shouldPresentAsk(
        folderKey: "/same", currentRootPath: "/ws", declinedFolders: ["/same"]),
      "排队期间被「仅打开文件」拒绝：同一会话不重复询问"
    )
    XCTAssertFalse(
      ExternalOpenCoordinator.shouldPresentAsk(
        folderKey: "/other", currentRootPath: "/other", declinedFolders: []),
      "排队期间工作区已切进该文件夹：无需再问"
    )
    XCTAssertTrue(
      ExternalOpenCoordinator.shouldPresentAsk(
        folderKey: "/other", currentRootPath: "/ws", declinedFolders: []))
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
