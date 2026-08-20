import PDFKit
import XCTest
@testable import MarkPDF

/// FR-4.5 标注列表单测：子类型映射、同组合并、排序逻辑、revision 同步
@MainActor
final class AnnotationListTests: XCTestCase {
  private let suiteName = "AnnotationListTests"
  private var dir: URL!
  private var store: PDFAnnotationStore!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AnnotationListTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    store = PDFAnnotationStore(defaults: defaults)
  }

  override func tearDownWithError() throws {
    removeTestDefaultsSuite(suiteName, using: defaults)
    try? FileManager.default.removeItem(at: dir)
  }

  private func makeDocument(pages: Int = 2) -> (PDFDocument, URL) {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let image = NSImage(size: NSSize(width: 200, height: 200))
    image.addRepresentation(rep)
    let doc = PDFDocument()
    for index in 0..<pages {
      doc.insert(PDFPage(image: image)!, at: index)
    }
    let url = dir.appendingPathComponent("\(UUID().uuidString).pdf")
    doc.write(to: url)
    return (doc, url)
  }

  private func highlight(y: CGFloat, groupID: String? = nil, color: NSColor = .yellow) -> PDFAnnotation {
    let annotation = PDFAnnotation(
      bounds: NSRect(x: 10, y: y, width: 80, height: 12),
      forType: .highlight,
      withProperties: nil
    )
    annotation.userName = groupID
    annotation.color = color
    return annotation
  }

  // MARK: - 子类型映射

  func testKindMappingCoversManagedKinds() {
    let cases: [(PDFAnnotationSubtype, AnnotationKind)] = [
      (.highlight, .highlight),
      (.underline, .underline),
      (.strikeOut, .strikeOut),
      (.freeText, .freeText),
    ]
    for (subtype, expected) in cases {
      let annotation = PDFAnnotation(bounds: .zero, forType: subtype, withProperties: nil)
      XCTAssertEqual(AnnotationKind.of(annotation), expected, "\(subtype.rawValue) 应映射为 \(expected)")
    }
  }

  func testPopupAnnotationIsNotManaged() {
    let popup = PDFAnnotation(bounds: .zero, forType: .text, withProperties: nil)
    XCTAssertNil(AnnotationKind.of(popup), "Text/便签已从产品移除，不应进入列表")
  }

  // MARK: - 列表快照

  func testSameGroupAnnotationsMergeIntoOneItem() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    // 组 ID 必须是 UUID 形态（PDFKit 会自动把系统用户名写进 userName，不能误当组 ID）
    let groupID = UUID().uuidString
    for annotation in [
      highlight(y: 150, groupID: groupID),
      highlight(y: 130, groupID: groupID),
      highlight(y: 100), // 无组：独立条目
    ] {
      page.addAnnotation(annotation)
    }

    let items = store.annotationItems()
    XCTAssertEqual(items.count, 2)
    let grouped = items.first { $0.id == groupID }
    XCTAssertEqual(grouped?.annotations.count, 2)
    XCTAssertEqual(grouped?.pageLabel, 1)
    XCTAssertEqual(grouped?.kind, .highlight)
  }

  /// 作者名形态的 userName（PDFKit 自动填系统用户名/预览写作者名）不得并组
  func testAuthorNameUserNameDoesNotGroup() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    for annotation in [
      highlight(y: 150, groupID: "why"),
      highlight(y: 130, groupID: "why"),
    ] {
      page.addAnnotation(annotation)
    }
    XCTAssertEqual(store.annotationItems().count, 2, "同作者名的两条标注应保持独立条目")
  }

  func testPopupCompanionIsExcludedFromItems() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    // PDFKit 添加 /Text 便签会自动补 Popup 伴侣，两者都不应出现在列表
    let note = PDFAnnotation(bounds: NSRect(x: 150, y: 150, width: 22, height: 22), forType: .text, withProperties: nil)
    page.addAnnotation(note)
    page.addAnnotation(highlight(y: 50))
    XCTAssertEqual(store.annotationItems().count, 1)
  }

  /// revision 刷新有 300ms 防抖（批注输入每键 markDirty 不能按键频全文档重扫）；
  /// 防抖窗口内的连续变更合并为一次刷新
  func testRevisionBumpsOnChanges() async {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let baseline = store.revision
    let page = doc.page(at: 0)!
    let annotation = highlight(y: 50)
    store.add(annotation, to: page)
    store.remove(annotation, from: page)
    try? await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(store.revision, baseline + 1, "防抖窗口内连续增删合并为一次 revision 刷新")
  }

  /// 交互期间（批注编辑框/编辑条打开）不重扫也不落盘：全文档重扫与 PDF 全量写回都在主线程，
  /// 落在打字/点色那一瞬会卡住 UI（实测新建批注要等约 1 秒才能输入）
  func testInteractionDefersRescanUntilResumed() async {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    var interacting = true
    let checkID = store.registerInteractionCheck { interacting }
    defer { store.unregisterInteractionCheck(checkID) }
    let baseline = store.revision
    let page = doc.page(at: 0)!

    store.add(highlight(y: 50), to: page)
    try? await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(store.revision, baseline, "交互期间不重扫")
    XCTAssertTrue(store.hasUnsavedChanges, "但改动已标脏（flush 兜底仍会写）")

    interacting = false
    store.resumeDeferredWrites()
    try? await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(store.revision, baseline + 1, "交互结束后统一排一次")
  }

  /// 进入编辑前撤下已排的落盘：新建批注的 markDirty 早于编辑框出现，
  /// 那次防抖写回正好砸在光标该闪的时刻
  func testDeferPendingWritesCancelsScheduledRescan() async {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let baseline = store.revision
    let page = doc.page(at: 0)!

    store.add(highlight(y: 50), to: page)  // 已排 0.3s 重扫 / 0.5s 写回
    store.deferPendingWrites()  // 编辑框即将出现 → 撤下
    try? await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(store.revision, baseline, "已排的重扫被撤下")

    store.resumeDeferredWrites()
    try? await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(store.revision, baseline + 1, "关闭编辑框后补上")
  }

  /// PDFKit 原生编辑锁定判定：所有标注一律锁（含 Link）——资料 PDF 给目录/选项行
  /// 铺满不可见 Link，不锁就会冒出带手柄的蓝框并抢走该区域的文本选择（实测多页复现）
  func testNativeEditingLockCoversAllAnnotations() {
    for type in [PDFAnnotationSubtype.highlight, .widget, .square, .text, .link] {
      let annotation = PDFAnnotation(bounds: .zero, forType: type, withProperties: nil)
      XCTAssertTrue(
        PDFAnnotationStore.shouldLockNativeEditing(annotation),
        "\(type.rawValue) 必须锁掉原生编辑")
    }
  }

  /// 点选删除/改色只认自己管理的标注：点目录 Link 不得冒出虚线框 + 垃圾桶（实测）
  func testOnlyManagedAnnotationsEnterClickSelection() {
    for type in [PDFAnnotationSubtype.highlight, .underline, .strikeOut, .freeText, .text] {
      let annotation = PDFAnnotation(bounds: .zero, forType: type, withProperties: nil)
      XCTAssertTrue(
        AnnotationToolbarController.isManagedAnnotation(annotation),
        "\(type.rawValue) 属于本 App 管理")
    }
    for type in [PDFAnnotationSubtype.link, .widget, .square, .circle, .stamp] {
      let annotation = PDFAnnotation(bounds: .zero, forType: type, withProperties: nil)
      XCTAssertFalse(
        AnnotationToolbarController.isManagedAnnotation(annotation),
        "\(type.rawValue) 是 PDF 自带，不参与点选删除")
    }
  }

  /// 新建普通标注写标准 `/F` ReadOnly，而不是仅写 Widget `/Ff`。
  func testAddedAnnotationHasStandardReadOnlyFlag() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    let annotation = highlight(y: 50)
    store.add(annotation, to: page)
    let flags = (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "F")) as? NSNumber)?.intValue ?? 0
    XCTAssertNotEqual(flags & PDFAnnotationStore.annotationReadOnlyFlag, 0)
    XCTAssertNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "Ff")), "普通 Highlight 不应伪写 Widget flags")
  }

  func testWidgetLockKeepsFieldReadOnlyAndStandardAnnotationFlag() {
    let widget = PDFAnnotation(bounds: .zero, forType: .widget, withProperties: nil)
    PDFAnnotationStore.lockNativeInteraction(of: widget)
    let flags = (widget.value(forAnnotationKey: PDFAnnotationKey(rawValue: "F")) as? NSNumber)?.intValue ?? 0
    XCTAssertNotEqual(flags & PDFAnnotationStore.annotationReadOnlyFlag, 0)
    XCTAssertTrue(widget.isReadOnly)
  }

  func testPortableVisibilityClearsNoViewFlag() {
    for subtype in [PDFAnnotationSubtype.text, .underline] {
      let annotation = PDFAnnotation(bounds: .zero, forType: subtype, withProperties: nil)
      annotation.shouldDisplay = false
      XCTAssertTrue(PDFAnnotationStore.restorePortableVisibility(of: annotation))
      XCTAssertTrue(annotation.shouldDisplay)
      let flags = (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "F")) as? NSNumber)?.intValue ?? 0
      XCTAssertEqual(flags & (1 << 5), 0, "NoView 必须清除，第三方阅读器才能显示")
    }
  }

  // MARK: - 排序

  private func item(pageIndex: Int, y: CGFloat = 100, kind: AnnotationKind = .highlight, color: NSColor = .yellow) -> AnnotationItem {
    let annotation = PDFAnnotation(bounds: NSRect(x: 10, y: y, width: 80, height: 12), forType: .highlight, withProperties: nil)
    return AnnotationItem(
      id: UUID().uuidString,
      annotations: [annotation],
      kind: kind,
      color: color,
      pageIndex: pageIndex,
      excerpt: "",
      name: ""
    )
  }

  func testSortByPageThenVisualOrder() {
    let items = [
      item(pageIndex: 2),
      item(pageIndex: 1, y: 100),
      item(pageIndex: 1, y: 150), // 同页 y 大者（更靠上）排前
    ]
    let sorted = AnnotationSort.page.sort(items)
    XCTAssertEqual(sorted[0].pageIndex, 1)
    XCTAssertEqual(sorted[0].annotations.first?.bounds.maxY, 162)
    XCTAssertEqual(sorted[1].pageIndex, 1)
    XCTAssertEqual(sorted[2].pageIndex, 2)
  }

  func testSortByColor() {
    let items = [
      item(pageIndex: 1, color: AnnotationColor.red.nsColor),
      item(pageIndex: 2, color: AnnotationColor.yellow.nsColor),
      item(pageIndex: 3, color: AnnotationColor.green.nsColor),
    ]
    let sorted = AnnotationSort.color.sort(items)
    XCTAssertEqual(sorted.map(\.pageIndex), [2, 3, 1], "应黄→绿→红（色板序）")
  }

  func testSortByType() {
    let items = [
      item(pageIndex: 1, kind: .strikeOut),
      item(pageIndex: 2, kind: .highlight),
      item(pageIndex: 3, kind: .underline),
    ]
    let sorted = AnnotationSort.type.sort(items)
    XCTAssertEqual(sorted.map(\.kind), [.highlight, .underline, .strikeOut])
  }

  // MARK: - 点选改色（FR-4.4）

  /// 编辑条上的「当前色」按最近色板项标注：PDF 里存的颜色常与四色有色差
  /// （外部阅读器创建、颜色空间转换）
  func testClosestColorMatchesPaletteEvenWithDrift() {
    for color in AnnotationColor.allCases {
      XCTAssertEqual(AnnotationColor.closest(to: color.nsColor), color, "同色必须自匹配")
    }
    // 略偏的黄（色差）仍归黄
    let driftedYellow = NSColor(red: 0.98, green: 0.80, blue: 0.28, alpha: 1)
    XCTAssertEqual(AnnotationColor.closest(to: driftedYellow), .yellow)
    // 深红归红、天蓝归蓝
    XCTAssertEqual(AnnotationColor.closest(to: NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)), .red)
    XCTAssertEqual(AnnotationColor.closest(to: NSColor(red: 0.3, green: 0.7, blue: 0.95, alpha: 1)), .blue)
  }

  /// 只有文本标记类可改色（批注走编辑框，其颜色不在此路径改）
  func testOnlyMarkupKindsAreRecolorable() {
    XCTAssertEqual(AnnotationColor.recolorableKinds, [.highlight, .underline, .strikeOut])
    XCTAssertFalse(AnnotationColor.recolorableKinds.contains(.freeText))
  }

  /// 改色经 store.update 写回：颜色即时生效且列表快照随之刷新（同组一起改）
  func testRecolorUpdatesAnnotationAndSnapshot() {
    let (doc, url) = makeDocument()
    store.attach(document: doc, url: url)
    let page = doc.page(at: 0)!
    let groupID = UUID().uuidString
    for annotation in [highlight(y: 150, groupID: groupID), highlight(y: 130, groupID: groupID)] {
      annotation.color = AnnotationColor.yellow.nsColor
      page.addAnnotation(annotation)
    }

    for annotation in page.annotations {
      store.update(annotation) { $0.color = AnnotationColor.green.nsColor }
    }
    XCTAssertTrue(
      page.annotations.allSatisfy { AnnotationColor.closest(to: $0.color) == .green },
      "同组标注一起改色"
    )
    XCTAssertEqual(
      store.annotationItems().map { AnnotationColor.closest(to: $0.color) },
      [.green],
      "列表快照按新颜色呈现（同组合并为一条）"
    )
  }
/// 批注图标避让（内容串台回归）：新图标绝不与既有图标重叠——
/// 重叠让点选命中歧义，点新图标实际编辑旧标注
final class CommentCollisionTests: XCTestCase {
  private let size: CGFloat = 22

  func testNoCollisionKeepsInitialY() {
    let y = AnnotationToolbarController.avoidIconCollision(
      initialY: 400, size: size,
      existingRects: [CGRect(x: 0, y: 100, width: size, height: size)])
    XCTAssertEqual(y, 400, "无重叠不动")
  }

  func testCollisionMovesAboveWithGap() {
    let existing = CGRect(x: 0, y: 300, width: size, height: size)
    let y = AnnotationToolbarController.avoidIconCollision(
      initialY: 310, size: size, existingRects: [existing])
    XCTAssertEqual(y, existing.minY - size - 4, "重叠时挪到碰撞图标上方 4pt")
    XCTAssertFalse(
      CGRect(x: 0, y: y, width: size, height: size).intersects(existing),
      "不得重叠")
  }

  func testDenseStackNeverOverlaps() {
    // 21 个图标叠成一串：20 轮耗尽后必须落到全部图标下方且不重叠
    var rects: [CGRect] = []
    for index in 0..<21 {
      rects.append(CGRect(x: 0, y: CGFloat(100 + index * 10), width: size, height: size))
    }
    let y = AnnotationToolbarController.avoidIconCollision(
      initialY: 105, size: size, existingRects: rects)
    let finalRect = CGRect(x: 0, y: y, width: size, height: size)
    XCTAssertTrue(
      rects.allSatisfy { !$0.intersects(finalRect) },
      "密集堆叠兜底后不得与任何既有图标重叠（y=\(y)）")
    XCTAssertLessThanOrEqual(y, rects.map(\.minY).min()! - size - 4, "应落在全部图标下方")
  }
}

}
