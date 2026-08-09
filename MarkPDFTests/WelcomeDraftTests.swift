import XCTest
@testable import MarkPDF

/// 欢迎草稿清场策略：打开真实文件时，未触碰的「未命名」欢迎草稿随开随关
/// （打开已有文件/工作区不再垫欢迎页）；用户编辑过的草稿必须保留（草稿不落盘，关了即丢）
@MainActor
final class WelcomeDraftTests: XCTestCase {
  private let fileURL = URL(fileURLWithPath: "/tmp/welcome-draft-note.md")

  func testOpeningFileClosesUntouchedWelcomeDraft() {
    let store = TabStore()
    XCTAssertEqual(store.groups[0].tabs.count, 1)
    XCTAssertNil(store.groups[0].tabs[0].url, "初始只有一张欢迎草稿")

    store.open(url: fileURL)

    XCTAssertEqual(
      store.groups[0].tabs.compactMap(\.url), [fileURL],
      "未触碰的欢迎草稿应随真实文件打开而关闭"
    )
  }

  func testEditedDraftSurvivesFileOpen() {
    let store = TabStore()
    store.activeEditorStore?.contentDidChange("用户动过字")

    store.open(url: fileURL)

    XCTAssertEqual(store.groups[0].tabs.count, 2, "编辑过的草稿必须保留")
    XCTAssertEqual(store.groups[0].activeTab?.url, fileURL, "新文件照常激活")
  }

  func testActivatingAlreadyOpenFileAlsoCleansWelcomeDraft() {
    let store = TabStore()
    store.open(url: fileURL)
    store.groups[0].openDraft()  // 用户又开了一张欢迎草稿（未触碰）

    store.open(url: fileURL)  // 再次点击已打开的文件

    XCTAssertEqual(
      store.groups[0].tabs.compactMap(\.url), [fileURL],
      "激活已打开文件同样清掉未触碰的欢迎草稿"
    )
  }
}
