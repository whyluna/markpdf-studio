import Foundation
import os

/// 传输层抽象（规范 §3.2：Core/Services 协议化，测试注入假实现）
protocol AITransport: Sendable {
  /// 一次性请求（非流式）
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
  /// 流式请求（返回 SSE 原始字节块流；非 2xx 直接抛 AIServiceError.httpStatus，响应体附摘录）
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error>
}

struct URLSessionAITransport: AITransport {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AIServiceError.invalidResponse
    }
    return (data, http)
  }

  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
    // dataDelegate 通道拿原始字节块。不能用 bytes.lines：AsyncBytes.lines 会丢弃空行，
    // 而空行恰是 SSE 事件边界（实测 anthropic 流全部事件粘连、零产出）
    AsyncThrowingStream { continuation in
      let delegate = SSEStreamDelegate(continuation: continuation)
      let streamSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
      let task = streamSession.dataTask(with: request)
      task.resume()
      continuation.onTermination = { _ in
        task.cancel()
        streamSession.invalidateAndCancel()
      }
    }
  }
}

/// SSE 流式代理（FR-AI.4）：2xx 转发原始字节块；非 2xx 攒错误体，
/// 完成时抛 httpStatus（附 200 字摘录，便于用户定位鉴权/配额问题）
private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private var statusCode: Int?
  private var errorBody = Data()

  init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
    self.continuation = continuation
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    statusCode = (response as? HTTPURLResponse)?.statusCode
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    if let statusCode, (200..<300).contains(statusCode) {
      continuation.yield(data)
    } else {
      errorBody.append(data)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      continuation.finish(throwing: error)
    } else if let statusCode, !(200..<300).contains(statusCode) {
      continuation.finish(throwing: AIServiceError.httpStatus(
        statusCode,
        String(decoding: errorBody, as: UTF8.self).truncated(to: 200)
      ))
    } else if statusCode == nil {
      continuation.finish(throwing: AIServiceError.invalidResponse)
    } else {
      continuation.finish()
    }
    session.finishTasksAndInvalidate()
  }
}

/// AI 服务门面（FR-AI.4）：请求构造 → 传输 → 增量解析；不持有任何 UI 状态。
/// @MainActor 与全部 Store 一致（开发规范 §3.3）；网络等待为异步挂起，不占主线程。
@MainActor
final class AIService {
  private let transport: AITransport
  private let keys: AIKeyStore

  init(transport: AITransport = URLSessionAITransport(), keys: AIKeyStore) {
    self.transport = transport
    self.keys = keys
  }

  /// 联通性测试（设置页「连接测试」）：发最小消息，返回往返耗时（秒）
  @discardableResult
  func testConnection(kind: AIProviderKind, config: AIProviderConfig) async throws -> TimeInterval {
    let start = Date()
    _ = try await complete(kind: kind, config: config, messages: [.user("ping")], maxTokens: 16)
    return Date().timeIntervalSince(start)
  }

  /// 非流式对话：一次性返回全文（划词翻译等短任务用）
  func complete(
    kind: AIProviderKind,
    config: AIProviderConfig,
    messages: [AIChatMessage],
    maxTokens: Int = 4096
  ) async throws -> String {
    let request = try makeRequest(kind: kind, config: config, messages: messages, stream: false, maxTokens: maxTokens)
    let (data, http) = try await transport.send(request)
    guard (200..<300).contains(http.statusCode) else {
      throw AIServiceError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self).truncated(to: 200))
    }
    switch kind.family {
    case .openAICompatible:
      return try AIResponseDecoder.openAIMessage(from: data)
    case .anthropic:
      return try AIResponseDecoder.anthropicMessage(from: data)
    }
  }

  /// 流式对话：逐段 yield 文本增量（AI 助手对话用）；取消消费方即断流
  func stream(
    kind: AIProviderKind,
    config: AIProviderConfig,
    messages: [AIChatMessage],
    maxTokens: Int = 4096
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task { [transport] in
        do {
          let request = try makeRequest(kind: kind, config: config, messages: messages, stream: true, maxTokens: maxTokens)
          let chunks = try await transport.stream(request)
          var parser = AISSEParser()
          for try await chunk in chunks {
            for event in parser.feed(chunk) {
              if let delta = try Self.delta(of: kind, from: event), !delta.isEmpty {
                continuation.yield(delta)
              }
            }
          }
          // 收尾：末尾事件无空行边界时由 finish 冲刷出来
          for event in parser.finish() {
            if let delta = try Self.delta(of: kind, from: event), !delta.isEmpty {
              continuation.yield(delta)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// 单个 SSE 事件 → 文本增量（nil = 哨兵/无内容/忽略事件）
  private static func delta(of kind: AIProviderKind, from event: AISSEParser.Event) throws -> String? {
    switch kind.family {
    case .openAICompatible:
      return try AIChunkDecoder.openAIDelta(from: event.data)
    case .anthropic:
      if case .delta(let text) = try AIChunkDecoder.anthropicDelta(event: event.name, payload: event.data) {
        return text
      }
      return nil
    }
  }

  // MARK: - 私有

  private func makeRequest(
    kind: AIProviderKind,
    config: AIProviderConfig,
    messages: [AIChatMessage],
    stream: Bool,
    maxTokens: Int
  ) throws -> URLRequest {
    guard let apiKey = keys.apiKey(for: kind.rawValue), !apiKey.isEmpty else {
      throw AIServiceError.missingAPIKey
    }
    // 日志只记 Provider 与条数，不落消息正文（开发规范 §6/§10）
    Logger.ai.debug("AI 请求: \(kind.rawValue) stream=\(stream) 消息 \(messages.count) 条")
    return try AIRequestBuilder.chatRequest(
      family: kind.family,
      config: config,
      apiKey: apiKey,
      messages: messages,
      stream: stream,
      maxTokens: maxTokens
    )
  }
}

private extension String {
  func truncated(to limit: Int) -> String {
    count > limit ? String(prefix(limit)) + "…" : self
  }
}
