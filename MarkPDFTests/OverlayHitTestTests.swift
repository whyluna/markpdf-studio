import AppKit
import XCTest

@testable import MarkPDF

/// OverlayPassthroughView 命中测试（回归锁）：NSView.hitTest 的入参是
/// 「父视图坐标系」的点，穿透容器必须原样透传给子视图——曾误做二次
/// convert，偏离原点的工具条/卡片命中区全部错位：点击穿透清掉 PDF 选区、
/// 批注卡片点不中（标注添加/修改双双失效的根因）
final class OverlayPassthroughViewTests: XCTestCase {
  func testOffsetSubviewHitUsesSuperviewCoords() {
    let host = OverlayPassthroughView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
    let button = NSButton(frame: NSRect(x: 300, y: 300, width: 60, height: 30))
    host.addSubview(button)

    // 按钮中心（父视图坐标）必须命中按钮本体
    let hit = host.hitTest(NSPoint(x: 330, y: 315))
    XCTAssertTrue(hit === button || (hit.map { button.isDescendant(of: $0) } ?? false))
  }

  func testEmptyAreaPassesThrough() {
    let host = OverlayPassthroughView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
    let button = NSButton(frame: NSRect(x: 300, y: 300, width: 60, height: 30))
    host.addSubview(button)

    // 空白点返回 nil：事件落到同帧下方的 PDFView
    XCTAssertNil(host.hitTest(NSPoint(x: 100, y: 100)))
  }

  func testHiddenHostInterceptsNothing() {
    let host = OverlayPassthroughView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
    let button = NSButton(frame: host.bounds)
    host.addSubview(button)
    host.isHidden = true

    XCTAssertNil(host.hitTest(NSPoint(x: 250, y: 250)))
  }
}
