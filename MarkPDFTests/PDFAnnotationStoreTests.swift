import PDFKit
import XCTest

@testable import MarkPDF

/// FR-4.4 颜色系统单测：各类型默认色、最近用色按类型独立记忆、UserDefaults 持久化
@MainActor
final class PDFAnnotationStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    // 固定 suite 名 + 用前清场：避免 UUID 随机名在磁盘堆积 plist
    suiteName = "PDFAnnotationStoreTests"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDownWithError() throws {
    removeTestDefaultsSuite(suiteName, using: defaults)
  }

  private func makeStore() -> PDFAnnotationStore {
    PDFAnnotationStore(writer: LiveAnnotationWriter(), defaults: defaults)
  }

  func testDefaultColorsWhenNothingPersisted() {
    let store = makeStore()
    XCTAssertEqual(store.colorsByKind[.highlight], .yellow)
    XCTAssertEqual(store.colorsByKind[.underline], .blue)
    XCTAssertEqual(store.colorsByKind[.strikeOut], .red)
    XCTAssertEqual(store.paletteKind, .highlight)
  }

  func testRememberIsPerKind() {
    let store = makeStore()
    store.remember(color: .red, for: .highlight)
    XCTAssertEqual(store.colorsByKind[.highlight], .red)
    // 其他类型保持自己的默认色
    XCTAssertEqual(store.colorsByKind[.underline], .blue)
    XCTAssertEqual(store.colorsByKind[.strikeOut], .red)
  }

  func testRememberedColorPersistsAcrossInstances() {
    makeStore().remember(color: .green, for: .underline)
    let reloaded = makeStore()
    XCTAssertEqual(reloaded.colorsByKind[.underline], .green)
    // 未改动的类型仍是默认色
    XCTAssertEqual(reloaded.colorsByKind[.highlight], .yellow)
  }

  func testCorruptPersistedValueFallsBackToDefault() {
    defaults.set("not-a-color", forKey: "annotationColor.highlight")
    XCTAssertEqual(makeStore().colorsByKind[.highlight], .yellow)
  }

  // MARK: - 写回失败上报（NFR-5）

  /// 构造一页空白 PDF（NSImage 需含真实位图内容，否则 PDFPage 拒绝）
  private func makePDFDocument() -> PDFDocument {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 100,
      pixelsHigh: 100,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )!
    let image = NSImage(size: NSSize(width: 100, height: 100))
    image.addRepresentation(rep)
    let doc = PDFDocument()
    doc.insert(PDFPage(image: image)!, at: 0)
    return doc
  }

  /// 写回失败必须经 lastError 上报；持续失败只提示一次，写回恢复后复位
  func testWriteBackFailureReportsOnceAndRecovers() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFAnnotationStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("a.pdf")
    let doc = makePDFDocument()
    XCTAssertTrue(doc.write(to: url))

    let store = makeStore()
    store.attach(document: doc, url: url)
    XCTAssertNil(store.lastError)

    // 原文件消失 → 首次写回创建 .bak 失败 → 上报
    try FileManager.default.removeItem(at: url)
    store.markDirty()
    store.flushPendingWrites()
    XCTAssertNotNil(store.lastError, "写回失败必须上报")

    // 持续失败不重复上报（每次标注变更都会重试，防弹窗轰炸）
    store.lastError = nil
    store.markDirty()
    store.flushPendingWrites()
    XCTAssertNil(store.lastError, "持续失败只提示一次")

    // 写回恢复成功后复位；再次失败会再次上报
    XCTAssertTrue(doc.write(to: url))
    store.markDirty()
    store.flushPendingWrites()
    XCTAssertFalse(store.hasUnsavedChanges, "恢复后应写回成功")
    try FileManager.default.removeItem(at: url)
    try FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
    store.markDirty()
    store.flushPendingWrites()
    XCTAssertNotNil(store.lastError, "恢复后再失败应再次上报")
  }

  // MARK: - FR-7.4 审查修复：权限不足提示附补救引导

  /// 权限错误识别（裸开工作区外 PDF 时同目录新建 .bak/.tmp/.json 必 EPERM）
  func testIsPermissionError() {
    XCTAssertTrue(PDFAnnotationStore.isPermissionError(
      NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
    XCTAssertTrue(PDFAnnotationStore.isPermissionError(
      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
    XCTAssertTrue(PDFAnnotationStore.isPermissionError(
      NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
    XCTAssertTrue(PDFAnnotationStore.isPermissionError(
      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    // POSIX 原因包在 underlying error 里也算
    XCTAssertTrue(PDFAnnotationStore.isPermissionError(
      NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])))
    XCTAssertFalse(PDFAnnotationStore.isPermissionError(
      NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    XCTAssertFalse(PDFAnnotationStore.isPermissionError(AnnotationWriteError.writeFailed))
  }

  /// 权限不足写回失败（只读目录下无法新建 .bak，模拟裸开工作区外文件的沙盒 EPERM）：
  /// 提示须附「设为工作区」补救引导
  func testPermissionWriteFailureGuidesSetWorkspace() throws {
    let (dir, url, doc) = try makePDFFixture()
    defer {
      // 先恢复可写再清理（只读目录删不动）
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

    let store = makeStore()
    store.attach(document: doc, url: url)
    store.markDirty()
    store.flushPendingWrites()

    let error = try XCTUnwrap(store.lastError, "写回失败必须上报")
    XCTAssertTrue(error.contains("设为工作区"), "权限不足须附补救引导，实际: \(error)")
  }

  /// 非权限错误（原文件丢失）：沿用原提示，不附工作区引导
  func testNonPermissionWriteFailureKeepsOriginalMessage() throws {
    let (dir, url, doc) = try makePDFFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.removeItem(at: url)

    let store = makeStore()
    store.attach(document: doc, url: url)
    store.markDirty()
    store.flushPendingWrites()

    let error = try XCTUnwrap(store.lastError, "写回失败必须上报")
    XCTAssertFalse(error.contains("设为工作区"), "非权限错误不应附工作区引导，实际: \(error)")
  }

  // MARK: - 防抖窗口内 flush 写回（Bug C1 回归）

  /// 建临时目录 + 落盘一页 PDF，返回 (目录, 文件 URL, 文档)
  private func makePDFFixture() throws -> (URL, URL, PDFDocument) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFAnnotationStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("a.pdf")
    let doc = makePDFDocument()
    XCTAssertTrue(doc.write(to: url))
    return (dir, url, doc)
  }

  private func makeHighlight() -> PDFAnnotation {
    PDFAnnotation(
      bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
      forType: .highlight, withProperties: nil)
  }

  /// 切档/关窗路径依赖：标注变更后未过 500ms 防抖期即 flushPendingWrites，
  /// 写回必须立即执行（此前仅靠防抖触发，视图清空 document 后弱引用失效会静默丢失）
  func testFlushPendingWritesWithinDebounceWindow() throws {
    let (dir, url, doc) = try makePDFFixture()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = makeStore()
    store.attach(document: doc, url: url)
    store.add(makeHighlight(), to: doc.page(at: 0)!)
    XCTAssertTrue(store.hasUnsavedChanges, "变更后应处于待写回状态（防抖窗口内）")

    store.flushPendingWrites()
    XCTAssertFalse(store.hasUnsavedChanges, "flush 后不应有未写回改动")
    XCTAssertNil(store.lastError)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
      "flush 必须立即执行写回（.bak 在首次写回前创建）")
  }

  /// 切换只读模式前先落盘挂起改动（Bug C1 同类）：否则变更会被写进新目的地
  func testSetSidecarModeFlushesPendingWritesBeforeSwitch() throws {
    let (dir, url, doc) = try makePDFFixture()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = makeStore()
    store.attach(document: doc, url: url)
    store.add(makeHighlight(), to: doc.page(at: 0)!)

    store.setSidecarMode(true)
    XCTAssertTrue(store.isSidecarMode)
    XCTAssertFalse(store.hasUnsavedChanges, "切换写回通道前必须落盘挂起改动")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
      "挂起改动应在切换前写回 PDF 本体")
  }

  // MARK: - 分栏焦点切换 attach（Bug 回归：共享 Store 把 A 窗标注写进 B 文档）

  /// attach 替换目标前必须先落盘旧文档的挂起改动：分栏双 PDF 焦点在 A/B 间切换时，
  /// A 的标注改动必须写回 A 的文件，不能随 store 指向切换写进 B 或静默丢失
  func testAttachFlushesPendingWritesOfPreviousDocument() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("PDFAnnotationStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let urlA = dir.appendingPathComponent("a.pdf")
    let urlB = dir.appendingPathComponent("b.pdf")
    let docA = makePDFDocument()
    let docB = makePDFDocument()
    XCTAssertTrue(docA.write(to: urlA))
    XCTAssertTrue(docB.write(to: urlB))

    let store = makeStore()
    store.attach(document: docA, url: urlA)
    store.add(makeHighlight(), to: docA.page(at: 0)!)
    XCTAssertTrue(store.hasUnsavedChanges, "变更后应处于待写回状态（防抖窗口内）")

    // 焦点切到 B：attach 替换目标前 flush A
    store.attach(document: docB, url: urlB)
    XCTAssertEqual(store.currentFileURL, urlB)
    XCTAssertFalse(store.hasUnsavedChanges, "attach 替换目标前必须落盘旧文档的挂起改动")
    XCTAssertEqual(
      PDFDocument(url: urlA)?.page(at: 0)?.annotations.count, 1,
      "A 的挂起标注必须写回 A 的文件")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: urlB.appendingPathExtension("bak").path),
      "B 无任何改动，不应被写回")
  }

  /// 重复 attach 同一文档是 no-op：分栏焦点认领每次点击都会调用 attach，
  /// 不得吞掉防抖窗口内的脏标记，也不得触发标注列表刷新
  func testReattachSameDocumentIsNoOp() throws {
    let (dir, url, doc) = try makePDFFixture()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = makeStore()
    store.attach(document: doc, url: url)
    store.add(makeHighlight(), to: doc.page(at: 0)!)
    let revisionBefore = store.revision

    store.attach(document: doc, url: url)
    XCTAssertTrue(store.hasUnsavedChanges, "同一文档重复 attach 不得吞掉挂起改动")
    XCTAssertEqual(store.revision, revisionBefore, "同一文档重复 attach 不得触发列表刷新")
  }

  // MARK: - Popup 伴侣摘除（蓝框吞划词回归）

  /// 回归：从磁盘加载回来的 Popup 伴侣类名是基类 PDFAnnotation，此前 attach 按
  /// `is PDFAnnotationPopup` 判类导致漏摘——残留伴侣留在 /Annots 里参与命中测试，
  /// PDFView 给它画带手柄的蓝框并吃掉那块区域的划词（有批注的页点正文即出框）
  func testAttachRemovesPopupLoadedAsBaseClass() throws {
    let (dir, url, doc) = try makePDFFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let page = doc.page(at: 0)!
    let popup = PDFAnnotation(
      bounds: CGRect(x: 8, y: 20, width: 128, height: 64),
      forType: .popup, withProperties: nil)
    page.addAnnotation(popup)
    let highlight = makeHighlight()
    page.addAnnotation(highlight)
    XCTAssertFalse(popup is PDFAnnotationPopup, "磁盘加载形态的前提：伴侣不是 PDFAnnotationPopup")

    makeStore().attach(document: doc, url: url)

    XCTAssertFalse(page.annotations.contains { $0.isPopup }, "Popup 伴侣必须从页面摘除")
    XCTAssertTrue(page.annotations.contains { $0 === highlight }, "普通标注不得被连带摘除")
    XCTAssertTrue(highlight.isReadOnly, "标注须锁掉 PDFKit 原生编辑")
  }

  /// isPopup 兼容 PDFKit 上报的两种子类型形态
  func testIsPopupAcceptsBothSubtypeForms() {
    let annotation = PDFAnnotation(bounds: .zero, forType: .popup, withProperties: nil)
    XCTAssertTrue(annotation.isPopup)
    XCTAssertFalse(makeHighlight().isPopup)
  }
}
