import XCTest

@testable import MarkPDF

/// NFR-5：文件读写失败必须用户可感知（lastError 上报）；自动保存持续失败只提示一次
final class EditorStoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EditorStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func testLoadFileFailureSetsLastError() {
    let store = EditorStore()
    store.loadFile(dir.appendingPathComponent("不存在.md"))
    XCTAssertNotNil(store.lastError, "读取失败必须上报")
    XCTAssertNil(store.currentFileURL, "失败后不应指向该文件")
  }

  func testAutosaveFailureReportsOnceAndRecovers() throws {
    let url = dir.appendingPathComponent("a.md")
    try "初始".write(to: url, atomically: true, encoding: .utf8)
    let store = EditorStore()
    store.loadFile(url)
    XCTAssertNil(store.lastError)

    // 目录消失 → 原子写盘必失败 → 首次失败上报
    try FileManager.default.removeItem(at: dir)
    store.contentDidChange("改动 1")
    store.flushPendingSave()
    XCTAssertNotNil(store.lastError, "保存失败必须上报")

    // 持续失败不重复上报（内容每变一次都会重试，防击键级弹窗轰炸）
    store.lastError = nil
    store.contentDidChange("改动 2")
    store.flushPendingSave()
    XCTAssertNil(store.lastError, "持续失败只提示一次")

    // 写盘恢复成功后复位；再次失败会再次上报
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    store.contentDidChange("改动 3")
    store.flushPendingSave()
    XCTAssertFalse(store.hasUnsavedChanges, "恢复后应写盘成功")
    try FileManager.default.removeItem(at: dir)
    store.contentDidChange("改动 4")
    store.flushPendingSave()
    XCTAssertNotNil(store.lastError, "恢复后再失败应再次上报")
  }
}
