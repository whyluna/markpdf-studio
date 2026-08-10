import PDFKit
import XCTest

@testable import MarkPDF

/// 体验修复批次四：视图层提炼出的守卫/工具纯函数单测
///（缩放同步守卫、书签页码守卫、改名提交守卫、批注光标 UTF-16 计数）
@MainActor
final class ViewLayerLogicTests: XCTestCase {
  // MARK: - 缩放同步守卫（Bug 修复 2）

  /// 加载窗口期（document 未挂载）不得同步缩放：此时 scaleFactor 仍是初值 1.0，
  /// 若 store 残留旧文档倍率 2.0，同步会误关 autoScales，新文档失去自适应宽度
  func testScaleSyncSkippedWhileDocumentLoading() {
    XCTAssertFalse(
      PDFReaderView.shouldSyncScale(hasDocument: false, scaleFactor: 1.0, targetScale: 2.0),
      "加载窗口期必须跳过缩放同步")
  }

  /// 文档就绪且目标倍率与当前值有差异时正常同步（按钮/快捷键缩放路径）
  func testScaleSyncAppliesWhenLoadedAndDiffers() {
    XCTAssertTrue(
      PDFReaderView.shouldSyncScale(hasDocument: true, scaleFactor: 1.0, targetScale: 2.0))
  }

  /// 差异在容差内不同步（避免 PDFKit 自适应微浮动反复触发）
  func testScaleSyncSkippedWithinTolerance() {
    XCTAssertFalse(
      PDFReaderView.shouldSyncScale(hasDocument: true, scaleFactor: 1.0, targetScale: 1.0005))
  }

  // MARK: - 捏合落定判定（「缩小后滚动被放大」修复）

  /// 缺 `.ended` 时（阶段事件偶发丢失）也要落定：否则图层变换悬着——
  /// 视觉已缩小但真实倍率与右下角比例都没变，随后任何重排丢弃变换就「弹回」
  func testPinchCommitsOnEndCancelAndUnknownPhase() {
    for phase in [NSEvent.Phase.ended, .cancelled, []] as [NSEvent.Phase] {
      XCTAssertTrue(
        PDFReaderView.Coordinator.shouldCommitPinch(phase: phase, isPinching: true),
        "阶段 \(phase.rawValue) 应落定")
    }
  }

  /// 手势推进中不落定（否则每帧真实重排，卡顿）
  func testPinchNotCommittedWhileInProgress() {
    XCTAssertFalse(
      PDFReaderView.Coordinator.shouldCommitPinch(phase: .began, isPinching: true))
    XCTAssertFalse(
      PDFReaderView.Coordinator.shouldCommitPinch(phase: .changed, isPinching: true))
    XCTAssertFalse(
      PDFReaderView.Coordinator.shouldCommitPinch(phase: .mayBegin, isPinching: true),
      "mayBegin 早于 began，不得当成结束")
  }

  /// 非捏合期间任何阶段都不落定（幂等：滚动兜底与看门狗可随意调用）
  func testPinchCommitIgnoredWhenNotPinching() {
    XCTAssertFalse(
      PDFReaderView.Coordinator.shouldCommitPinch(phase: .ended, isPinching: false))
  }

  // MARK: - 浮动面板几何守卫（NaN 崩溃修复）

  /// 选区 bounds 为 CGRect.null 时，页→视图变换会算出 NaN/inf；
  /// 交给 setFrame 会让 AppKit 直接 trap（实测 "Invalid view geometry: x is NaN"）
  func testPanelGeometryRejectsNonFiniteInput() {
    let container = NSRect(x: 0, y: 0, width: 800, height: 600)
    let size = NSSize(width: 240, height: 120)
    XCTAssertTrue(
      AnnotationToolbarController.isDisplayableGeometry(
        viewBounds: NSRect(x: 100, y: 100, width: 80, height: 12),
        panelSize: size, container: container))
    for bad in [CGFloat.nan, .infinity, -.infinity] {
      XCTAssertFalse(
        AnnotationToolbarController.isDisplayableGeometry(
          viewBounds: NSRect(x: bad, y: 100, width: 80, height: 12),
          panelSize: size, container: container),
        "选区几何 \(bad) 必须拒绝")
      XCTAssertFalse(
        AnnotationToolbarController.isDisplayableGeometry(
          viewBounds: NSRect(x: 100, y: 100, width: 80, height: 12),
          panelSize: NSSize(width: bad, height: 120), container: container),
        "面板尺寸 \(bad) 必须拒绝")
    }
    XCTAssertFalse(
      AnnotationToolbarController.isDisplayableGeometry(
        viewBounds: NSRect(x: 100, y: 100, width: 80, height: 12),
        panelSize: size, container: .null),
      "容器为 null 矩形（无穷）必须拒绝")
  }

  /// 容器过窄/面板尺寸为零（首次布局未完成）也不定位：夹取会算出负宽度
  func testPanelGeometryRejectsDegenerateContainer() {
    let size = NSSize(width: 240, height: 120)
    let bounds = NSRect(x: 10, y: 10, width: 80, height: 12)
    XCTAssertFalse(
      AnnotationToolbarController.isDisplayableGeometry(
        viewBounds: bounds, panelSize: size, container: NSRect(x: 0, y: 0, width: 10, height: 600)))
    XCTAssertFalse(
      AnnotationToolbarController.isDisplayableGeometry(
        viewBounds: bounds, panelSize: .zero,
        container: NSRect(x: 0, y: 0, width: 800, height: 600)))
  }

  // MARK: - 书签页码守卫（Bug 修复 4）

  /// 异步加载完成前 currentPage == 0：0 页书签永远跳不到（goTo 有 page>=1 防护），不得产生死书签
  func testBookmarkablePageRequiresLoadedDocument() {
    XCTAssertFalse(PDFSidebarView.isBookmarkablePage(0), "加载窗口期（第 0 页）不得加书签")
    XCTAssertFalse(PDFSidebarView.isBookmarkablePage(-1))
    XCTAssertTrue(PDFSidebarView.isBookmarkablePage(1))
  }

  // MARK: - 改名提交守卫（Bug 修复 7）

  /// 失焦提交仅对仍处于改名状态的条目生效：Esc 取消会先清 renamingID，
  /// 随后输入框移除引发的失焦回调不得把已取消的文本写回
  func testRenameCommitGuard() {
    XCTAssertTrue(
      AnnotationListView.shouldCommitRename(renamingID: "a", itemID: "a"),
      "改名中失焦必须提交")
    XCTAssertFalse(
      AnnotationListView.shouldCommitRename(renamingID: nil, itemID: "a"),
      "Esc 取消后（renamingID 已清空）失焦回调不得提交")
    XCTAssertFalse(
      AnnotationListView.shouldCommitRename(renamingID: "b", itemID: "a"),
      "已切到别的条目改名时不得提交旧条目")
  }

  // MARK: - 批注光标 UTF-16 计数（Bug 修复 5）

  /// setSelectedRange 按 UTF-16 计数：String.count 是 Character 数，
  /// 含 emoji（占 2 个 UTF-16 码元）时会少算，光标落进文本中间
  func testUTF16LengthCountsEmojiAsTwoUnits() {
    XCTAssertEqual(AnnotationToolbarController.utf16Length(of: "abc"), 3)
    XCTAssertEqual(AnnotationToolbarController.utf16Length(of: "批注😀"), 4)
    XCTAssertEqual(AnnotationToolbarController.utf16Length(of: ""), 0)
    // 前置：旧写法 String.count 与 UTF-16 长度在含 emoji 时确实不同
    XCTAssertEqual("批注😀".count, 3, "前置：Character 计数把 emoji 算 1")
  }

  /// 真实 NSTextView 验证：按 UTF-16 长度定位，光标落在文末（旧写法会落在 emoji 码元中间）
  func testCursorLandsAtTextEndWithEmoji() {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    textView.string = "批注😀"
    textView.setSelectedRange(
      NSRange(location: AnnotationToolbarController.utf16Length(of: textView.string), length: 0))
    XCTAssertEqual(
      textView.selectedRange().location, 4,
      "光标必须落在文末（UTF-16 计数，emoji 占 2 码元）")
  }
}

