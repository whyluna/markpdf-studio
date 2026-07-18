import Foundation
import WebKit
import os

/// Swift ↔ Web 唯一消息通道（开发规范 §3.4）。
/// 信封格式：`{ id?: string, type: string, payload: object }`
/// - native → web：`window.bridge.receive(envelope)`
/// - web → native：`window.webkit.messageHandlers.bridge.postMessage(envelope)`
final class WebBridge: NSObject {
  static let handlerName = "bridge"

  typealias Handler = (_ payload: [String: Any], _ id: String?) -> Void

  enum BridgeError: LocalizedError {
    case timeout(String)
    case invalidBody

    var errorDescription: String? {
      switch self {
      case .timeout(let type): "桥接请求超时（3s）：\(type)"
      case .invalidBody: "桥接消息体格式非法"
      }
    }
  }

  private weak var webView: WKWebView?
  private var handlers: [String: Handler] = [:]
  private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
  private var pendingTimeouts: [String: DispatchWorkItem] = [:]

  /// 绑定到指定 WKWebView，并注册脚本消息处理器
  func attach(to webView: WKWebView) {
    self.webView = webView
    webView.configuration.userContentController.add(self, name: Self.handlerName)
  }

  func detach() {
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
    webView = nil
  }

  /// 注册 web → native 的消息处理器
  func on(_ type: String, handler: @escaping Handler) {
    handlers[type] = handler
  }

  /// native → web 单向通知
  func notify(_ type: String, payload: [String: Any] = [:]) {
    send(["type": type, "payload": payload])
  }

  /// 应答 web 侧带 id 的请求
  func respond(id: String, payload: [String: Any] = [:]) {
    send(["id": id, "type": "bridge.response", "payload": payload])
  }

  /// native → web 请求-响应（3s 超时）
  func request(
    _ type: String,
    payload: [String: Any] = [:],
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    let id = "native-\(UUID().uuidString)"
    pending[id] = completion

    let timeout = DispatchWorkItem { [weak self] in
      guard let self, let callback = self.pending.removeValue(forKey: id) else { return }
      self.pendingTimeouts.removeValue(forKey: id)
      Logger.editor.error("\(BridgeError.timeout(type).localizedDescription)")
      callback(.failure(BridgeError.timeout(type)))
    }
    pendingTimeouts[id] = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)

    send(["id": id, "type": type, "payload": payload])
  }

  // MARK: - Private

  private func send(_ envelope: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(envelope),
      let data = try? JSONSerialization.data(withJSONObject: envelope),
      let json = String(data: data, encoding: .utf8)
    else {
      // os_log 插值需要具体类型；Any 会让类型检查器报不出诊断（compiler bug 面）
      let typeName = envelope["type"] as? String ?? "?"
      Logger.editor.error("\(BridgeError.invalidBody.localizedDescription): \(typeName)")
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.webView?.evaluateJavaScript("window.bridge.receive(\(json))") { _, error in
        if let error {
          // WKError userInfo 里有 JS 异常详情（message/行号），比 localizedDescription 有用得多
          let info = (error as NSError).userInfo
          let msg = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
          let line = info["WKJavaScriptExceptionLineNumber"] as? Int ?? 0
          let column = info["WKJavaScriptExceptionColumnNumber"] as? Int ?? 0
          let typeName = envelope["type"] as? String ?? "?"
          Logger.editor.error("bridge 发送失败[\(typeName)]: \(msg, privacy: .public) (line \(line):\(column))")
        }
      }
    }
  }
}

// MARK: - WKScriptMessageHandler

extension WebBridge: WKScriptMessageHandler {
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == Self.handlerName,
      let body = message.body as? [String: Any],
      let type = body["type"] as? String
    else { return }

    let id = body["id"] as? String
    let payload = body["payload"] as? [String: Any] ?? [:]

    // 请求-响应：按 id 匹配挂起的 completion
    if let id, let completion = pending.removeValue(forKey: id) {
      pendingTimeouts.removeValue(forKey: id)?.cancel()
      completion(.success(payload))
      return
    }

    if let handler = handlers[type] {
      handler(payload, id)
    } else {
      Logger.editor.debug("未注册的消息类型: \(type)")
    }
  }
}
