import UniformTypeIdentifiers
import XCTest
@testable import MarkPDF

/// 默认打开方式开关（LaunchServices 封装）：fake provider 驱动三态判定与设置后刷新
final class DefaultHandlerServiceTests: XCTestCase {
  private final class FakeProvider: DefaultHandlerProviding {
    var handlers: [String: URL] = [:]
    var setCalls: [(URL, UTType)] = []
    var setError: Error?

    func defaultHandlerURL(for type: UTType) -> URL? {
      handlers[type.identifier]
    }

    func setDefaultHandler(appURL: URL, for type: UTType, completion: @escaping (Error?) -> Void) {
      setCalls.append((appURL, type))
      if setError == nil {
        handlers[type.identifier] = appURL
      }
      completion(setError)
    }
  }

  /// 测试宿主是 MarkPDF.app：Bundle.main 即本应用，bundleURL 可当"我是默认"样本
  private let selfURL = Bundle.main.bundleURL
  private let selfID = Bundle.main.bundleIdentifier ?? "com.whyluna.markpdf"
  private let otherApp = URL(fileURLWithPath: "/System/Applications/Preview.app")

  @MainActor
  func testRefreshReflectsSystemState() {
    let provider = FakeProvider()
    provider.handlers[DefaultHandlerService.pdfType.identifier] = selfURL
    provider.handlers[DefaultHandlerService.markdownType.identifier] = otherApp
    let service = DefaultHandlerService(provider: provider, appBundleID: selfID, appURL: selfURL)

    service.refresh()
    XCTAssertTrue(service.isDefaultPDF)
    XCTAssertFalse(service.isDefaultMarkdown, "他 App 是默认时开关应为关")
  }

  @MainActor
  func testNoHandlerMeansOff() {
    let service = DefaultHandlerService(provider: FakeProvider(), appBundleID: selfID, appURL: selfURL)
    service.refresh()
    XCTAssertFalse(service.isDefaultMarkdown)
    XCTAssertFalse(service.isDefaultPDF)
  }

  @MainActor
  func testSetAsDefaultFlipsStateAfterRefresh() {
    let provider = FakeProvider()
    let service = DefaultHandlerService(provider: provider, appBundleID: selfID, appURL: selfURL)
    service.refresh()
    XCTAssertFalse(service.isDefaultPDF)

    service.setAsDefault(for: .pdf)
    XCTAssertEqual(provider.setCalls.count, 1)
    XCTAssertEqual(provider.setCalls.first?.1, DefaultHandlerService.pdfType)
    XCTAssertTrue(service.isDefaultPDF, "set 完成回调后应重查并翻转")
    XCTAssertFalse(service.isDefaultMarkdown, "另一类型不受影响")
  }

  @MainActor
  func testSetFailureKeepsStateOff() {
    let provider = FakeProvider()
    provider.setError = NSError(domain: "test", code: 1)
    let service = DefaultHandlerService(provider: provider, appBundleID: selfID, appURL: selfURL)
    service.setAsDefault(for: .markdown)
    XCTAssertFalse(service.isDefaultMarkdown)
  }
}
