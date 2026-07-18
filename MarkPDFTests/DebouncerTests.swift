import XCTest
@testable import MarkPDF

/// 防抖器单测（§9.3）：连续触发只执行最后一次；取消后不执行。
final class DebouncerTests: XCTestCase {
  func testCoalescesBursts() {
    let debouncer = Debouncer(interval: 0.05)
    var calls: [Int] = []
    let expectation = expectation(description: "只执行最后一次")
    debouncer.schedule { calls.append(1) }
    debouncer.schedule { calls.append(2) }
    debouncer.schedule {
      calls.append(3)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
    XCTAssertEqual(calls, [3])
  }

  func testCancel() {
    let debouncer = Debouncer(interval: 0.05)
    var called = false
    debouncer.schedule { called = true }
    debouncer.cancel()
    let expectation = expectation(description: "等待超过防抖间隔")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
    XCTAssertFalse(called)
  }
}
