import XCTest

@testable import MarkPDF

/// WebBridge 生命周期回归：detach/deinit 必须给挂起的请求统一失败回调，
/// 否则调用方（AI 选区采集等请求-响应链路）永久悬挂、静默卡死
final class WebBridgeTests: XCTestCase {

  /// detach 时：所有挂起请求立即以 detached 失败回调，超时器取消
  func testDetachFailsPendingRequests() {
    let bridge = WebBridge()
    var results: [Result<[String: Any], Error>] = []
    bridge.request(.getSelection) { results.append($0) }
    bridge.request(.exportHTML) { results.append($0) }

    bridge.detach()

    XCTAssertEqual(results.count, 2, "detach 必须回调全部挂起请求")
    for result in results {
      guard case .failure(let error) = result, case WebBridge.BridgeError.detached = error else {
        return XCTFail("期望 detached 失败回调，实际 \(String(describing: result))")
      }
    }
  }

  /// bridge 释放（deinit）同样兜底失败回调（超时器的 weak self 失效前必须收口）
  func testDeinitFailsPendingRequests() {
    var results: [Result<[String: Any], Error>] = []
    autoreleasepool {
      let bridge = WebBridge()
      bridge.request(.getSelection) { results.append($0) }
    }
    XCTAssertEqual(results.count, 1, "deinit 必须回调挂起请求")
    guard case .failure(let error) = results.first,
      case WebBridge.BridgeError.detached = error
    else {
      return XCTFail("期望 detached 失败回调，实际 \(String(describing: results.first))")
    }
  }
}
