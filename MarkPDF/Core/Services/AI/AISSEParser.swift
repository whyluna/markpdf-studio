import Foundation

/// SSE（Server-Sent Events）增量解析器（FR-AI.4）：纯值类型，可单测。
/// 处理跨 chunk 半行（按 \n 字节切分，UTF-8 多字节字符不会被截断）、
/// \r\n 行尾、注释/心跳行（: 开头）、多行 data 合并；[DONE] 等哨兵由上层判定。
struct AISSEParser {
  struct Event: Equatable {
    /// event: 字段（OpenAI 兼容协议不用；Anthropic 用来区分 delta/stop/error）
    var name: String?
    /// data: 字段（多行以 \n 合并）
    var data: String
  }

  private var buffer = Data()
  private var dataLines: [String] = []
  private var eventName: String?

  mutating func feed(_ chunk: Data) -> [Event] {
    buffer.append(chunk)
    var events: [Event] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = buffer[buffer.startIndex..<newline]
      buffer.removeSubrange(buffer.startIndex...newline)
      if line.last == 0x0D {
        line = line.dropLast()
      }
      if let event = process(String(decoding: line, as: UTF8.self)) {
        events.append(event)
      }
    }
    return events
  }

  /// 流结束时冲刷：尾行无换行符也算一条，残余未派发数据一并收尾
  mutating func finish() -> [Event] {
    var events: [Event] = []
    if !buffer.isEmpty {
      if let event = process(String(decoding: buffer, as: UTF8.self)) {
        events.append(event)
      }
      buffer.removeAll()
    }
    if let event = flush() {
      events.append(event)
    }
    return events
  }

  /// 处理一行；返回解析完成的事件（空行为事件边界）
  private mutating func process(_ line: String) -> Event? {
    if line.isEmpty {
      return flush()
    }
    if line.hasPrefix(":") {
      return nil
    }
    if line.hasPrefix("data:") {
      dataLines.append(Self.trimOneLeadingSpace(String(line.dropFirst(5))))
      return nil
    }
    if line.hasPrefix("event:") {
      eventName = Self.trimOneLeadingSpace(String(line.dropFirst(6)))
      return nil
    }
    // id: / retry: 等字段用不到，忽略
    return nil
  }

  private mutating func flush() -> Event? {
    defer {
      dataLines = []
      eventName = nil
    }
    guard !dataLines.isEmpty else { return nil }
    return Event(name: eventName, data: dataLines.joined(separator: "\n"))
  }

  private static func trimOneLeadingSpace(_ string: String) -> String {
    string.hasPrefix(" ") ? String(string.dropFirst()) : string
  }
}
