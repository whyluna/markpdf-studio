import XCTest
@testable import MarkPDF

/// 多窗口路由（v1.5）：已打开则聚焦、否则开新窗；纯函数判定矩阵
final class WindowCoordinatorTests: XCTestCase {
  private let fileA = URL(fileURLWithPath: "/tmp/wsA/paper.pdf")
  private let outsideFile = URL(fileURLWithPath: "/tmp/loose/note.md")

  // MARK: - 外部打开文件

  func testExternalFileAlreadyOpenFocusesThatWindow() {
    let windows = [
      WindowCoordinator.WindowInfo(rootPath: "/tmp/wsB"),
      WindowCoordinator.WindowInfo(rootPath: nil, openFilePaths: [WindowCoordinator.normalize(outsideFile)]),
    ]
    XCTAssertEqual(
      WindowCoordinator.routeExternalFile(outsideFile, windows: windows),
      .focusExisting(windowIndex: 1, openTab: nil),
      "已打开该文件的窗口直接聚焦（不重复开，避免同文件双窗口冲突）"
    )
  }

  func testExternalFileInsideWorkspaceOpensTabThere() {
    let windows = [
      WindowCoordinator.WindowInfo(rootPath: "/tmp/other"),
      WindowCoordinator.WindowInfo(rootPath: "/tmp/wsA"),
    ]
    XCTAssertEqual(
      WindowCoordinator.routeExternalFile(fileA, windows: windows),
      .focusExisting(windowIndex: 1, openTab: fileA),
      "某窗口工作区包含该文件 → 聚焦并在其中开标签"
    )
  }

  func testExternalFileUnrelatedOpensNewFileWindow() {
    let windows = [WindowCoordinator.WindowInfo(rootPath: "/tmp/wsA")]
    XCTAssertEqual(
      WindowCoordinator.routeExternalFile(outsideFile, windows: windows),
      .newWindow(.file(outsideFile)),
      "与现有工作区无关 → 新开单文件窗口（隔离，不污染现有工作区）"
    )
  }

  func testExternalFileWithNoWindowsOpensNewWindow() {
    XCTAssertEqual(
      WindowCoordinator.routeExternalFile(outsideFile, windows: []),
      .newWindow(.file(outsideFile))
    )
  }

  func testExternalFileAbsorbedByEmptyBareWindow() {
    let windows = [WindowCoordinator.WindowInfo(rootPath: nil)]
    XCTAssertEqual(
      WindowCoordinator.routeExternalFile(outsideFile, windows: windows),
      .focusExisting(windowIndex: 0, openTab: outsideFile),
      "无工作区且未开任何文件的空窗口就地承接（冷启动单文件打开不残留空窗口）"
    )
  }

  func testExternalFileBareWindowWithFilesStillOpensNewWindow() {
    let other = URL(fileURLWithPath: "/tmp/loose/other.pdf")
    let windows = [
      WindowCoordinator.WindowInfo(rootPath: nil, openFilePaths: [WindowCoordinator.normalize(other)]),
    ]
    XCTAssertEqual(
      WindowCoordinator.routeExternalFile(outsideFile, windows: windows),
      .newWindow(.file(outsideFile)),
      "已开其他文件的单文件窗口不吸收，保持隔离"
    )
  }

  func testWorkspaceMatchWinsOverEmptyBareWindow() {
    let windows = [
      WindowCoordinator.WindowInfo(rootPath: nil),
      WindowCoordinator.WindowInfo(rootPath: "/tmp/wsA"),
    ]
    XCTAssertEqual(
      WindowCoordinator.routeExternalFile(fileA, windows: windows),
      .focusExisting(windowIndex: 1, openTab: fileA),
      "工作区归属优先于空窗口承接"
    )
  }

  // MARK: - 打开工作区

  func testOpenWorkspaceAlreadyOpenFocuses() {
    let windows = [
      WindowCoordinator.WindowInfo(rootPath: "/tmp/wsA"),
      WindowCoordinator.WindowInfo(rootPath: "/tmp/wsB"),
    ]
    XCTAssertEqual(
      WindowCoordinator.routeWorkspace(URL(fileURLWithPath: "/tmp/wsB"), windows: windows, requestingIndex: 0),
      .focusExisting(windowIndex: 1, openTab: nil),
      "同一工作区不开两个窗口（双窗口会写同一槽位）"
    )
  }

  func testOpenWorkspaceFromWindowWithWorkspaceOpensNewWindow() {
    let windows = [WindowCoordinator.WindowInfo(rootPath: "/tmp/wsA")]
    XCTAssertEqual(
      WindowCoordinator.routeWorkspace(URL(fileURLWithPath: "/tmp/wsB"), windows: windows, requestingIndex: 0),
      .newWindow(.workspace(URL(fileURLWithPath: "/tmp/wsB"))),
      "已有工作区的窗口打开别的工作区 → 新窗口，本窗原样不动"
    )
  }

  func testOpenWorkspaceFromEmptyWindowOpensInPlace() {
    let windows = [WindowCoordinator.WindowInfo(rootPath: nil)]
    XCTAssertEqual(
      WindowCoordinator.routeWorkspace(URL(fileURLWithPath: "/tmp/wsB"), windows: windows, requestingIndex: 0),
      .focusExisting(windowIndex: 0, openTab: nil),
      "空窗口就地打开，不浪费窗口"
    )
  }

  func testOpenWorkspaceSubdirectoryStillNewWindow() {
    let windows = [WindowCoordinator.WindowInfo(rootPath: "/tmp/wsA")]
    XCTAssertEqual(
      WindowCoordinator.routeWorkspace(URL(fileURLWithPath: "/tmp/wsA/sub"), windows: windows, requestingIndex: 0),
      .newWindow(.workspace(URL(fileURLWithPath: "/tmp/wsA/sub"))),
      "子目录是不同工作区（用户显式选择收窄范围），开新窗口"
    )
  }

  // MARK: - 新窗口任务队列

  @MainActor
  func testRequestQueueIsFIFOAndDrains() {
    let coordinator = WindowCoordinator()
    var openCount = 0
    coordinator.openNewWindow = { openCount += 1 }
    coordinator.requestWindow(.file(outsideFile))
    coordinator.requestWindow(.workspace(URL(fileURLWithPath: "/tmp/wsB")))
    XCTAssertEqual(openCount, 2)
    XCTAssertEqual(coordinator.takePendingRequest(), .file(outsideFile))
    XCTAssertEqual(coordinator.takePendingRequest(), .workspace(URL(fileURLWithPath: "/tmp/wsB")))
    XCTAssertNil(coordinator.takePendingRequest(), "队列排空后新窗口显示空态（系统窗口恢复多开也不炸）")
  }

  @MainActor
  func testRequestForwardsSceneCreationWhenOpenWindowNotWired() {
    let coordinator = WindowCoordinator()
    var forwarded: [[URL]] = []
    coordinator.requestSceneCreation = { forwarded.append($0) }
    coordinator.requestWindow(.file(outsideFile))
    XCTAssertEqual(forwarded, [[outsideFile]], "零活窗且动作未接线：转发 open 事件强制建初始场景（冷启动 odoc 同款原语）")
    XCTAssertEqual(coordinator.takePendingRequest(), .file(outsideFile), "请求保留待新窗领取（转发建出的窗 onAppear 领取）")
  }

  @MainActor
  func testRequestDroppedWhenNothingCanCreateWindows() {
    let coordinator = WindowCoordinator()
    coordinator.requestWindow(.file(outsideFile))
    XCTAssertNil(coordinator.takePendingRequest(), "既无动作也无法建场景时不留悬挂任务（否则下个窗口领到过期任务）")
  }

  /// openWindow 动作调了但没建出窗（保留的动作在全部窗口关闭后失效）：
  /// 滞留探测兜底转发建场景
  @MainActor
  func testStalenessProbeForwardsUnclaimedRequest() {
    let coordinator = WindowCoordinator()
    coordinator.openNewWindow = {}
    coordinator.stalenessProbeDelay = 0.05
    var forwarded: [[URL]] = []
    coordinator.requestSceneCreation = { forwarded.append($0) }
    coordinator.requestWindow(.file(outsideFile))
    XCTAssertTrue(forwarded.isEmpty, "动作已接线先走动作，不立即转发")
    let expectation = expectation(description: "滞留探测转发")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
    wait(for: [expectation], timeout: 2)
    XCTAssertEqual(forwarded, [[outsideFile]], "任务滞留无窗领取 → 转发 open 事件兜底")
    XCTAssertEqual(coordinator.takePendingRequest(), .file(outsideFile), "任务仍保留给兜底建出的窗")
  }

  /// 多个滞留请求只能各转发一次；旧实现每个请求各排一个 probe，全部重复转发队首。
  @MainActor
  func testStalenessProbeForwardsEachQueuedRequestOnce() {
    let coordinator = WindowCoordinator()
    coordinator.openNewWindow = {}
    coordinator.stalenessProbeDelay = 0.05
    var forwarded: [[URL]] = []
    coordinator.requestSceneCreation = { forwarded.append($0) }
    let second = URL(fileURLWithPath: "/tmp/second.md")
    coordinator.requestWindow(.file(outsideFile))
    coordinator.requestWindow(.file(second))
    let expectation = expectation(description: "单批滞留探测")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
    wait(for: [expectation], timeout: 2)

    XCTAssertEqual(forwarded, [[outsideFile], [second]])
    XCTAssertEqual(coordinator.takePendingRequest(), .file(outsideFile))
    XCTAssertEqual(coordinator.takePendingRequest(), .file(second))
  }

  /// 最后一个窗口关闭后 openWindow 动作保留：零活窗时 Finder 双击文件仍能开窗
  @MainActor
  func testUnregisterKeepsOpenWindowAction() {
    let fixture = SessionFixture()
    let coordinator = WindowCoordinator()
    var openCount = 0
    coordinator.openNewWindow = { openCount += 1 }
    let session = fixture.makeSession(root: "/tmp/wsA")
    coordinator.register(session)
    coordinator.unregister(session)
    coordinator.requestWindow(.file(outsideFile))
    XCTAssertEqual(openCount, 1, "零活窗时请求仍走保留的 openWindow 动作")
  }

  // MARK: - 零活窗复活（B1）

  @MainActor
  func testReviveWindowlessQueuesNilRootRestore() {
    let coordinator = WindowCoordinator()
    coordinator.requestSceneCreation = { _ in }
    coordinator.reviveWindowIfWindowless()
    XCTAssertEqual(coordinator.takePendingRequest(), .restoreWorkspace(rootPath: nil), "无快照：走「最后工作区」路径恢复")
    coordinator.reviveWindowIfWindowless()
    XCTAssertNil(coordinator.takePendingRequest(), "已有复活任务在途不重复入队（防开一排窗）")
  }

  @MainActor
  func testReviveUsesRecordedWorkspaceRoots() {
    let fixture = SessionFixture()
    let coordinator = WindowCoordinator()
    coordinator.snapshotStore = fixture.snapshotStore
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("revive-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    coordinator.requestSceneCreation = { _ in }
    let session = fixture.makeSession(root: root)
    coordinator.register(session)
    coordinator.unregister(session)  // 回到零活窗
    // 本测试验证 WindowCoordinator 消费快照清单，不重复验证系统
    // ScopedBookmarksAgent；直接放入一条占位书签，确保无 GUI 的 xctest 也确定运行。
    fixture.snapshotStore.state.lastRootPath = root
    fixture.snapshotStore.state.bookmarks[root] = Data([0x01])
    coordinator.reviveWindowIfWindowless()
    XCTAssertEqual(coordinator.takePendingRequest(), .restoreWorkspace(rootPath: root), "按书签恢复记录过的工作区")
  }

  @MainActor
  func testReviveSkipsWhenWindowAlive() {
    let fixture = SessionFixture()
    let coordinator = WindowCoordinator()
    coordinator.register(fixture.makeSession(root: "/tmp/wsA"))
    coordinator.reviveWindowIfWindowless()
    XCTAssertNil(coordinator.takePendingRequest(), "有活窗不补")
  }

  /// 复活任务被新窗领取后，窗口再次全关 → 允许再次复活（didQueueRevival 在 register 复位）
  @MainActor
  func testReviveAllowedAgainAfterWindowComesAndGoes() {
    let fixture = SessionFixture()
    let coordinator = WindowCoordinator()
    coordinator.requestSceneCreation = { _ in }
    coordinator.reviveWindowIfWindowless()
    XCTAssertEqual(coordinator.takePendingRequest(), .restoreWorkspace(rootPath: nil))
    let session = fixture.makeSession(root: "/tmp/wsA")
    coordinator.register(session)
    coordinator.unregister(session)
    coordinator.reviveWindowIfWindowless()
    XCTAssertEqual(coordinator.takePendingRequest(), .restoreWorkspace(rootPath: nil), "复位后可再次入队复活任务")
  }

  @MainActor
  func testSceneRevivalURLs() {
    let folder = URL(fileURLWithPath: "/tmp/wsB")
    XCTAssertEqual(WindowCoordinator.WindowRequest.file(outsideFile).sceneRevivalURLs, [outsideFile])
    XCTAssertEqual(WindowCoordinator.WindowRequest.workspace(folder).sceneRevivalURLs, [folder])
    XCTAssertEqual(
      WindowCoordinator.WindowRequest.workspaceWithFile(root: folder, file: outsideFile).sceneRevivalURLs,
      [outsideFile])
    XCTAssertEqual(
      WindowCoordinator.WindowRequest.restoreWorkspace(rootPath: "/tmp/wsB").sceneRevivalURLs,
      [folder])
    // nil 根的中性驱动 URL：bundle 内 Info.plist（类型不在白名单，onOpenURL 忽略）
    let neutral = WindowCoordinator.WindowRequest.restoreWorkspace(rootPath: nil).sceneRevivalURLs
    XCTAssertEqual(neutral?.count, 1)
    XCTAssertEqual(neutral?.first?.lastPathComponent, "Info.plist")
  }

  /// 接受「设为工作区」时新窗口仍在队列中：任务原地升级（不再多开一个窗口）
  @MainActor
  func testUpgradeRewritesQueuedFileRequest() {
    let coordinator = WindowCoordinator()
    coordinator.openNewWindow = {}
    coordinator.requestWindow(.file(outsideFile))
    let root = URL(fileURLWithPath: "/tmp/loose")
    coordinator.upgradeExternalFileWindow(to: root, file: outsideFile)
    XCTAssertEqual(
      coordinator.takePendingRequest(),
      .workspaceWithFile(root: root, file: outsideFile)
    )
    XCTAssertNil(coordinator.takePendingRequest(), "只升级不追加")
  }

  // MARK: - 窗口清单采集（点 × 不是退出）

  /// 关窗即更新清单：点 × 只关窗、进程仍活着，重新激活（点 Dock 图标）时读磁盘清单——
  /// 只在退出时采集会让它停在上一次退出的旧状态，把早已关掉的工作区又开回来（实测）
  @MainActor
  func testUnregisterPublishesRemainingWorkspaceRoots() {
    let fixture = SessionFixture()
    let coordinator = WindowCoordinator()
    var published: [[String]] = []
    coordinator.onOpenWindowRootsChanged = { published.append($0) }
    let windowA = fixture.makeSession(root: "/tmp/wsA")
    let windowB = fixture.makeSession(root: "/tmp/wsB")
    coordinator.register(windowA)
    coordinator.register(windowB)

    coordinator.unregister(windowA)
    XCTAssertEqual(published.last, ["/tmp/wsB"], "关掉一个窗口后清单只剩另一个")
    coordinator.unregister(windowB)
    XCTAssertEqual(published.last, [], "零窗口写空清单 → 重新激活时回退「最后使用的工作区」")
  }

  /// 单文件窗口无工作区根，不占清单位（沙盒授权随进程失效，初版不恢复）
  @MainActor
  func testFileOnlyWindowNotInWorkspaceRoots() {
    let fixture = SessionFixture()
    let coordinator = WindowCoordinator()
    coordinator.register(fixture.makeSession(root: "/tmp/wsA"))
    coordinator.register(fixture.makeSession(root: nil))
    XCTAssertEqual(coordinator.workspaceRoots(), ["/tmp/wsA"])
  }

  /// 退出流程定格清单：⌘Q 的顺序是 willTerminate 写入完整清单 → 窗口逐个关闭，
  /// 若放任关窗改写，清单会被洗空，「退出后恢复全部窗口」失效
  @MainActor
  func testTerminationFreezesRootsAgainstWindowClosing() {
    let fixture = SessionFixture()
    let coordinator = WindowCoordinator()
    var published: [[String]] = []
    coordinator.onOpenWindowRootsChanged = { published.append($0) }
    let windowA = fixture.makeSession(root: "/tmp/wsA")
    let windowB = fixture.makeSession(root: "/tmp/wsB")
    coordinator.register(windowA)
    coordinator.register(windowB)

    coordinator.prepareForTermination()
    XCTAssertEqual(published.last, ["/tmp/wsA", "/tmp/wsB"], "退出时定格当时的全部窗口")
    coordinator.unregister(windowA)
    coordinator.unregister(windowB)
    XCTAssertEqual(published.last, ["/tmp/wsA", "/tmp/wsB"], "退出过程中关窗不得改写清单")
  }

  /// 窗口 session 工装：共享快照存储 + 内存密钥 + 临时全局会话目录（不碰用户真实数据）
  @MainActor
  private final class SessionFixture {
    private let suiteName = "WindowCoordinatorTests"
    private let defaults: UserDefaults
    let snapshotStore: WorkspaceSnapshotStore
    private let aiSettings: AISettingsStore
    private let aiKeys = AIKeyStore(storage: InMemoryAIKeyStorage())
    private let aiSessions: AISessionRepository
    /// 测试需强持有 session（coordinator 只按顺序登记）
    private var sessions: [WindowSession] = []

    init() {
      defaults = UserDefaults(suiteName: suiteName)!
      defaults.removePersistentDomain(forName: suiteName)
      snapshotStore = WorkspaceSnapshotStore(defaults: defaults)
      aiSettings = AISettingsStore(defaults: defaults)
      AISessionStore.globalStoreDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WindowCoordinatorTests-\(UUID().uuidString)")
      aiSessions = AISessionRepository()
    }

    deinit {
      try? FileManager.default.removeItem(at: AISessionStore.globalStoreDirectory)
      defaults.removePersistentDomain(forName: suiteName)
    }

    /// 建一个窗口 session；root 为 nil = 单文件窗口（无工作区）
    func makeSession(root: String?) -> WindowSession {
      let session = WindowSession(
        snapshotStore: snapshotStore,
        aiSettings: aiSettings,
        aiKeys: aiKeys,
        aiSessions: aiSessions
      )
      if let root {
        session.stateStore.workspaceDidChange(
          root: URL(fileURLWithPath: root), collapsedFolders: [])
      }
      sessions.append(session)
      return session
    }
  }
}
