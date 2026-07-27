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

/// 流式事件（FR-AI.2 v1.3）：文本增量实时到达；工具调用于流结束时整体给出（重组完成后）
enum AIStreamEvent: Equatable {
  case text(String)
  case toolCalls([AIToolCall])
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
  func testConnection(kind: AIProviderKind, config: AIProviderConfig, model: String) async throws -> TimeInterval {
    let start = Date()
    _ = try await complete(kind: kind, config: config, model: model, messages: [.user("ping")], maxTokens: 16)
    return Date().timeIntervalSince(start)
  }

  /// 非流式对话：一次性返回全文（划词翻译等短任务用）
  func complete(
    kind: AIProviderKind,
    config: AIProviderConfig,
    model: String,
    messages: [AIChatMessage],
    maxTokens: Int = 4096
  ) async throws -> String {
    let request = try makeRequest(kind: kind, config: config, model: model, messages: messages, stream: false, maxTokens: maxTokens)
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

  /// 流式对话：文本增量实时 yield，工具调用在流结束时整体 yield（AI 助手 agent 循环用）；
  /// 取消消费方即断流
  func stream(
    kind: AIProviderKind,
    config: AIProviderConfig,
    model: String,
    messages: [AIChatMessage],
    maxTokens: Int = 4096,
    tools: [AITool]? = nil
  ) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task { [transport] in
        do {
          let request = try makeRequest(kind: kind, config: config, model: model, messages: messages, stream: true, maxTokens: maxTokens, tools: tools)
          let chunks = try await transport.stream(request)
          var parser = AISSEParser()
          var openAIAccumulator = AIToolCallAccumulator.OpenAI()
          var anthropicAccumulator = AIToolCallAccumulator.Anthropic()

          func process(_ event: AISSEParser.Event) throws {
            switch kind.family {
            case .openAICompatible:
              guard let outcome = try AIChunkDecoder.openAIChunk(from: event.data) else { return }
              if let text = outcome.text, !text.isEmpty {
                continuation.yield(.text(text))
              }
              openAIAccumulator.ingest(outcome.toolCallDeltas)
            case .anthropic:
              switch try AIChunkDecoder.anthropicDelta(event: event.name, payload: event.data) {
              case .delta(let text) where !text.isEmpty:
                continuation.yield(.text(text))
              case .toolUseStart(let index, let id, let name):
                anthropicAccumulator.blockStart(index: index, id: id, name: name)
              case .inputJSONDelta(let index, let partial):
                anthropicAccumulator.ingest(index: index, partial: partial)
              default:
                break
              }
            }
          }

          for try await chunk in chunks {
            for event in parser.feed(chunk) {
              try process(event)
            }
          }
          // 收尾：末尾事件无空行边界时由 finish 冲刷出来
          for event in parser.finish() {
            try process(event)
          }
          let calls = kind.family == .openAICompatible
            ? openAIAccumulator.finalize()
            : anthropicAccumulator.finalize()
          if !calls.isEmpty {
            continuation.yield(.toolCalls(calls))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - 私有

  private func makeRequest(
    kind: AIProviderKind,
    config: AIProviderConfig,
    model: String,
    messages: [AIChatMessage],
    stream: Bool,
    maxTokens: Int,
    tools: [AITool]? = nil
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
      model: model,
      messages: messages,
      stream: stream,
      maxTokens: maxTokens,
      tools: tools
    )
  }
}

private extension String {
  func truncated(to limit: Int) -> String {
    count > limit ? String(prefix(limit)) + "…" : self
  }
}
