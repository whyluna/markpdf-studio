import XCTest
@testable import MarkPDF

/// 收藏夹与最近打开（FR-1.5）：增删、排序、去重、上限、按工作区隔离、持久化
final class FavoritesRecentsTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private let rootA = URL(fileURLWithPath: "/tmp/ws-a")
  private let rootB = URL(fileURLWithPath: "/tmp/ws-b")
  private let file1 = URL(fileURLWithPath: "/tmp/ws-a/笔记.md")
  private let file2 = URL(fileURLWithPath: "/tmp/ws-a/论文.pdf")

  override func setUp() {
    super.setUp()
    suiteName = "FavoritesRecentsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
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
  func testRecentsCappedAtLimit() {
    let store = RecentFilesStore(defaults: defaults)
    for i in 1...25 {
      store.record(URL(fileURLWithPath: "/tmp/ws-a/f\(i).md"), forRoot: rootA)
    }
    let files = store.files(forRoot: rootA)
    XCTAssertEqual(files.count, RecentFilesStore.limit)
    XCTAssertEqual(files.first, URL(fileURLWithPath: "/tmp/ws-a/f25.md"))
    XCTAssertEqual(files.last, URL(fileURLWithPath: "/tmp/ws-a/f6.md"))
  }

  @MainActor
  func testRecentsPersistAcrossInstances() {
    RecentFilesStore(defaults: defaults).record(file1, forRoot: rootA)
    let reopened = RecentFilesStore(defaults: defaults)
    XCTAssertEqual(reopened.files(forRoot: rootA), [file1])
  }
}
