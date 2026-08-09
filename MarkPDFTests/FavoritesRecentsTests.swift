import XCTest
@testable import MarkPDF

/// 收藏夹与最近打开（FR-1.5）：增删、排序、去重、上限、按工作区隔离、持久化
final class FavoritesRecentsTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var tempDir: URL!
  private var rootA: URL!
  private var rootB: URL!
  private var file1: URL!
  private var file2: URL!

  override func setUp() {
    super.setUp()
    // 固定 suite 名 + 用前清场：避免 UUID 随机名在磁盘堆积 plist（cfprefsd 不保证删文件）
    suiteName = "FavoritesRecentsTests"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
    // 真实临时文件（最近打开列表会按存在性自动清理，不能用虚构路径）
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FavoritesRecentsTests.\(UUID().uuidString)")
    rootA = tempDir.appendingPathComponent("ws-a")
    rootB = tempDir.appendingPathComponent("ws-b")
    try? FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
    file1 = rootA.appendingPathComponent("笔记.md")
    file2 = rootA.appendingPathComponent("论文.pdf")
    try? "a".write(to: file1, atomically: true, encoding: .utf8)
    try? "b".write(to: file2, atomically: true, encoding: .utf8)
  }

  override func tearDown() {
    removeTestDefaultsSuite(suiteName, using: defaults)
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  // MARK: - 收藏夹

  @MainActor
  func testFavoriteToggleAddRemove() {
    let store = FavoritesStore(defaults: defaults)
    XCTAssertFalse(store.contains(file1, forRoot: rootA))
    store.toggle(file1, forRoot: rootA)
    XCTAssertTrue(store.contains(file1, forRoot: rootA))
    store.toggle(file1, forRoot: rootA)
    XCTAssertFalse(store.contains(file1, forRoot: rootA))
  }

  @MainActor
  func testFavoritesKeepInsertionOrder() {
    let store = FavoritesStore(defaults: defaults)
    store.toggle(file2, forRoot: rootA)
    store.toggle(file1, forRoot: rootA)
    XCTAssertEqual(store.files(forRoot: rootA), [file2, file1])
  }

  @MainActor
  func testFavoritesIsolatedPerRoot() {
    let store = FavoritesStore(defaults: defaults)
    store.toggle(file1, forRoot: rootA)
    XCTAssertEqual(store.files(forRoot: rootB), [])
  }

  @MainActor
  func testFavoritesPersistAcrossInstances() {
    FavoritesStore(defaults: defaults).toggle(file1, forRoot: rootA)
    let reopened = FavoritesStore(defaults: defaults)
    XCTAssertEqual(reopened.files(forRoot: rootA), [file1])
  }

  // MARK: - 最近打开

  @MainActor
  func testRecentsNewestFirst() {
    let store = RecentFilesStore(defaults: defaults)
    store.record(file1, forRoot: rootA)
    store.record(file2, forRoot: rootA)
    XCTAssertEqual(store.files(forRoot: rootA), [file2, file1])
  }

  @MainActor
  func testRecentsReopenMovesToTop() {
    let store = RecentFilesStore(defaults: defaults)
    store.record(file1, forRoot: rootA)
    store.record(file2, forRoot: rootA)
    store.record(file1, forRoot: rootA)
    XCTAssertEqual(store.files(forRoot: rootA), [file1, file2])
  }

  @MainActor
  func testRecentsCappedAtLimit() throws {
    let store = RecentFilesStore(defaults: defaults)
    for i in 1...25 {
      let url = rootA.appendingPathComponent("f\(i).md")
      try "x".write(to: url, atomically: true, encoding: .utf8)
      store.record(url, forRoot: rootA)
    }
    let files = store.files(forRoot: rootA)
    XCTAssertEqual(files.count, RecentFilesStore.limit)
    XCTAssertEqual(files.first, rootA.appendingPathComponent("f25.md"))
    XCTAssertEqual(files.last, rootA.appendingPathComponent("f\(26 - RecentFilesStore.limit).md"))
  }

  @MainActor
  func testRecentsAutoCleansDeletedFiles() throws {
    // 真实临时文件：记录后删除其一。清理挪到写入路径（record）——读取为纯读，
    // 不在视图 body 求值期发布（展示层的存在性过滤由 FileTreeView.collectionSection 负责）
    // （目录须在工作区根内：工作区外文件自归属过滤起不再入最近打开）
    let dir = rootA.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let alive = dir.appendingPathComponent("alive.md")
    let dead = dir.appendingPathComponent("dead.md")
    try "a".write(to: alive, atomically: true, encoding: .utf8)
    try "b".write(to: dead, atomically: true, encoding: .utf8)

    let store = RecentFilesStore(defaults: defaults)
    store.record(alive, forRoot: rootA)
    store.record(dead, forRoot: rootA)
    try FileManager.default.removeItem(at: dead)

    // 纯读路径不再清理：原样返回（含已删除项）
    XCTAssertEqual(store.files(forRoot: rootA), [dead, alive])
    // 下一次写入顺带清理并回写存储：新实例读到的也是清理后的列表
    store.record(alive, forRoot: rootA)
    XCTAssertEqual(store.files(forRoot: rootA), [alive])
    let reopened = RecentFilesStore(defaults: defaults)
    XCTAssertEqual(reopened.files(forRoot: rootA), [alive])
  }

  @MainActor
  func testRecentsPersistAcrossInstances() {
    RecentFilesStore(defaults: defaults).record(file1, forRoot: rootA)
    let reopened = RecentFilesStore(defaults: defaults)
    XCTAssertEqual(reopened.files(forRoot: rootA), [file1])
  }

  // MARK: - 工作区归属过滤

  /// 工作区外的文件不记录（md 链接点开异根文件等路径会把外部文件送进来——
  /// 侧栏「最近打开」只应出现本工作区的文件，越界文件点了也没权限打开）
  @MainActor
  func testRecentsSkipsFilesOutsideRoot() throws {
    let outside = rootB.appendingPathComponent("外部.md")
    try "x".write(to: outside, atomically: true, encoding: .utf8)

    let store = RecentFilesStore(defaults: defaults)
    store.record(outside, forRoot: rootA)
    XCTAssertEqual(store.files(forRoot: rootA), [], "异根文件不记录")

    store.record(outside, forRoot: rootB)
    XCTAssertEqual(store.files(forRoot: rootB), [outside], "归属 B 根时照常记录")
  }

  /// 历史脏数据兼容：旧版本误录进某根的异根条目，读出时按归属滤掉（不显示即不可点）
  @MainActor
  func testRecentsFiltersLegacyForeignEntriesOnRead() {
    let foreign = rootB.appendingPathComponent("别的工作区.md")
    // 直接写底层存储模拟历史脏数据（record 的归属闸拦不住已存在的数据）
    defaults.set([rootA.path: [foreign.path, file1.path]], forKey: "recentFiles")

    let store = RecentFilesStore(defaults: defaults)
    XCTAssertEqual(store.files(forRoot: rootA), [file1], "异根条目读出即过滤")
  }

  // MARK: - 改名/移动跟随

  @MainActor
  func testRecentsRekeyFollowsFileRename() {
    let renamed = rootA.appendingPathComponent("笔记-新.md")
    let store = RecentFilesStore(defaults: defaults)
    store.record(file1, forRoot: rootA)

    store.rekey(from: file1.path, to: renamed.path)

    XCTAssertEqual(store.files(forRoot: rootA), [renamed], "改名后最近打开跟随新路径")
  }

  @MainActor
  func testRecentsRekeyShiftsFolderDescendantsAndDedupes() {
    let dir = rootA.appendingPathComponent("dir")
    let moved = rootA.appendingPathComponent("dir2")
    let inside = dir.appendingPathComponent("a.md")
    let alreadyThere = moved.appendingPathComponent("a.md")
    // 绕过归属闸直接写存储（平移冲突场景的构造与真实写入无关）；先写数据再建 store（init 时载入）
    defaults.set([rootA.path: [inside.path, alreadyThere.path]], forKey: "recentFiles")
    let store = RecentFilesStore(defaults: defaults)

    store.rekey(from: dir.path, to: moved.path)
    store.rekey(from: dir.path, to: moved.path)  // 幂等：第二次 no-op

    XCTAssertEqual(
      store.files(forRoot: rootA), [alreadyThere],
      "后代按前缀平移；平移后与已有条目去重，不剩两条"
    )
  }

  @MainActor
  func testFavoritesRekeyFollowsFolderMove() {
    let dir = rootA.appendingPathComponent("dir")
    let moved = rootA.appendingPathComponent("dir2")
    let inside = dir.appendingPathComponent("a.md")
    defaults.set([rootA.path: [inside.path, file1.path]], forKey: "favoriteFiles")
    let store = FavoritesStore(defaults: defaults)

    store.rekey(from: dir.path, to: moved.path)

    XCTAssertEqual(
      store.files(forRoot: rootA),
      [moved.appendingPathComponent("a.md"), file1],
      "收藏随文件夹移动平移，根下其他文件不动"
    )
  }
}
