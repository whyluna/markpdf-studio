import XCTest

final class MarkPDFUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// 冒烟：应用能启动并出现主窗口。
  func testLaunchShowsMainWindow() throws {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
  }
}
