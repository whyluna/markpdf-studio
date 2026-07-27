import XCTest
@testable import MarkPDF

/// AI 链路真实 HTTP 集成测试（FR-AI.4）：走 URLSessionAITransport 打本地 mock 服务器
/// （scripts/mock_ai_server.py），验证 请求构造 → 真实网络 → SSE 增量解析 → 解码 全链路。
/// 默认跳过：设置 AI_MOCK_BASE_URL 环境变量后运行，例如
///   python3 scripts/mock_ai_server.py &
///   AI_MOCK_BASE_URL=http://127.0.0.1:8787 xcodebuild test -only-testing:MarkPDFTests/AIIntegrationTests
final class AIIntegrationTests: XCTestCase {
  private var baseURL: String!

  override func setUpWithError() throws {
    // xcodebuild 会清洗传给测试进程的环境变量，故支持两个发现通道：
    // 环境变量（本地直跑 xctest 时可用）+ mock 启动时写的地址文件；文件可能过期，须探活
    let envURL = ProcessInfo.processInfo.environment["AI_MOCK_BASE_URL"]
    let fileURL = try? String(contentsOf: URL(fileURLWithPath: "/tmp/markpdf-ai-mock.url"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let candidate = envURL ?? fileURL, !candidate.isEmpty else {
      throw XCTSkip("未发现 mock 服务器（先启动 scripts/mock_ai_server.py）")
    }
    guard Self.isReachable(candidate) else {
      throw XCTSkip("mock 服务器不可达（地址文件可能过期）：\(candidate)")
    }
    baseURL = candidate
  }

  /// 探活：GET 根路径，能拿到任意 HTTP 响应即视为在线（501 也算）
  private static func isReachable(_ baseURL: String) -> Bool {
    guard let url = URL(string: baseURL) else { return false }
    let semaphore = DispatchSemaphore(value: 0)
    var reachable = false
    let task = URLSession.shared.dataTask(with: url) { _, response, _ in
      reachable = response is HTTPURLResponse
      semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 2)
    task.cancel()
    return reachable
  }

  @MainActor
  private func makeService(kind: AIProviderKind, key: String = "sk-mock") -> (AIService, AIProviderConfig) {
    let keys = AIKeyStore(storage: InMemoryAIKeyStorage())
    keys.save(key, for: kind.rawValue)
    let service = AIService(transport: URLSessionAITransport(), keys: keys)
    var config = kind.defaultConfig
    config.isEnabled = true
    // OpenAI 兼容端点形如 {baseURL}/chat/completions，预设 baseURL 均含 /v1，此处对齐
    config.baseURL = kind.family == .openAICompatible ? baseURL + "/v1" : baseURL
    return (service, config)
  }

  @MainActor
  func testOpenAICompleteOverHTTP() async throws {
    let (service, config) = makeService(kind: .deepseek)
    let text = try await service.complete(kind: .deepseek, config: config, model: config.models[0], messages: [.user("ping")])
    XCTAssertEqual(text, "pong")
  }

  @MainActor
  func testOpenAIStreamOverHTTP() async throws {
    let (service, config) = makeService(kind: .deepseek)
    var collected = ""
    for try await event in service.stream(kind: .deepseek, config: config, model: config.models[0], messages: [.user("hi")]) {
      if case .text(let delta) = event { collected += delta }
    }
    XCTAssertEqual(collected, "你好")
  }

  @MainActor
  func testAnthropicCompleteOverHTTP() async throws {
    let (service, config) = makeService(kind: .anthropic)
    let text = try await service.complete(kind: .anthropic, config: config, model: config.models[0], messages: [.user("ping")])
    XCTAssertEqual(text, "pong")
  }

  @MainActor
  func testAnthropicStreamOverHTTP() async throws {
    let (service, config) = makeService(kind: .anthropic)
    var collected = ""
    for try await event in service.stream(kind: .anthropic, config: config, model: config.models[0], messages: [.user("hi")]) {
      if case .text(let delta) = event { collected += delta }
    }
    XCTAssertEqual(collected, "你好")
  }

  @MainActor
  func testAuthFailureSurfacesStatusAndBody() async {
    let (service, config) = makeService(kind: .deepseek, key: "bad-key")
    do {
      _ = try await service.complete(kind: .deepseek, config: config, model: config.models[0], messages: [.user("ping")])
      XCTFail("bad-key 应被 mock 拒绝")
    } catch {
      guard case .httpStatus(let status, let snippet) = error as? AIServiceError else {
        return XCTFail("期望 httpStatus，实际 \(error)")
      }
      XCTAssertEqual(status, 401)
      XCTAssertTrue(snippet.contains("invalid api key"))
    }
  }

  @MainActor
  func testStreamAuthFailureSurfacesStatusAndBody() async {
    let (service, config) = makeService(kind: .anthropic, key: "bad-key")
    do {
      for try await _ in service.stream(kind: .anthropic, config: config, model: config.models[0], messages: [.user("hi")]) {}
      XCTFail("bad-key 应被 mock 拒绝")
    } catch {
      guard case .httpStatus(let status, _) = error as? AIServiceError else {
        return XCTFail("期望 httpStatus，实际 \(error)")
      }
      XCTAssertEqual(status, 401)
    }
  }
}
