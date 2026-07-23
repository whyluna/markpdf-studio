import XCTest
@testable import MarkPDF

/// SSE 增量解析（FR-AI.4）：跨 chunk 半行、\r\n、注释、多行 data、event 名、尾冲刷
final class AISSEParserTests: XCTestCase {
  func testBasicEvents() {
    var parser = AISSEParser()
    let events = parser.feed(Data("data: hello\n\ndata: world\n\n".utf8))
    XCTAssertEqual(events, [
      .init(name: nil, data: "hello"),
      .init(name: nil, data: "world"),
    ])
  }

  func testSplitChunkAcrossDataLine() {
    var parser = AISSEParser()
    XCTAssertEqual(parser.feed(Data("data: hel".utf8)), [])
    let events = parser.feed(Data("lo\n\n".utf8))
    XCTAssertEqual(events.map(\.data), ["hello"])
  }

  /// UTF-8 多字节字符跨 chunk 切分不损坏（按 \n 字节切行，字符边界天然安全）
  func testMultibyteUTF8AcrossChunks() {
    var parser = AISSEParser()
    let full = Data("data: 你好\n\n".utf8)
    XCTAssertEqual(parser.feed(full.prefix(7)), [])
    let events = parser.feed(full.suffix(full.count - 7))
    XCTAssertEqual(events.map(\.data), ["你好"])
  }

  func testCRLFAndCommentLines() {
    var parser = AISSEParser()
    let events = parser.feed(Data(": keep-alive\r\ndata: a\r\n\r\n".utf8))
    XCTAssertEqual(events.map(\.data), ["a"])
  }

  func testMultiLineDataJoinedWithNewline() {
    var parser = AISSEParser()
    let events = parser.feed(Data("data: line1\ndata: line2\n\n".utf8))
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.data, "line1\nline2")
  }

  func testEventNameCaptured() {
    var parser = AISSEParser()
    let events = parser.feed(Data("event: message_stop\ndata: {}\n\n".utf8))
    XCTAssertEqual(events.first?.name, "message_stop")
    XCTAssertEqual(events.first?.data, "{}")
  }

  func testFinishFlushesTrailingLineWithoutNewline() {
    var parser = AISSEParser()
    _ = parser.feed(Data("data: tail".utf8))
    let events = parser.finish()
    XCTAssertEqual(events.map(\.data), ["tail"])
  }

  /// 心跳注释不产生空事件
  func testOnlyCommentsYieldNoEvents() {
    var parser = AISSEParser()
    XCTAssertEqual(parser.feed(Data(": ping\n\n: pong\n\n".utf8)), [])
  }
}
