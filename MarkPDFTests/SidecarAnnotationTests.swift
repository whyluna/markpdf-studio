import PDFKit
import XCTest
@testable import MarkPDF

/// 只读模式 sidecar（FR-4.7）：序列化 round-trip、PDF 本体不动、模式持久化
final class SidecarAnnotationTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SidecarAnnotationTests.\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  /// 造一个含标注的单页 PDF
  private func makePDFFile() throws -> (url: URL, document: PDFDocument) {
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    let url = tempDir.appendingPathComponent("论文.pdf")
    try XCTUnwrap(document.dataRepresentation()).write(to: url)
    return (url, document)
  }

  @MainActor
  func testSidecarURLRule() {
    let pdf = URL(fileURLWithPath: "/tmp/论文.pdf")
    XCTAssertEqual(SidecarAnnotationStorage.sidecarURL(for: pdf).lastPathComponent, "论文.json")
  }

  @MainActor
  func testRoundTripPreservesAnnotations() throws {
    let (url, document) = try makePDFFile()
    let page = try XCTUnwrap(document.page(at: 0))
    let groupID = UUID().uuidString
    // 高亮组成员
    let highlight = PDFAnnotation(bounds: CGRect(x: 10, y: 20, width: 100, height: 12), forType: .highlight, withProperties: nil)
    highlight.color = NSColor(red: 1, green: 0.835, blue: 0.231, alpha: 1)
    highlight.userName = groupID
    page.addAnnotation(highlight)
    // 批注标记（/Text 图标，contents 为批注正文）
    let marker = PDFAnnotation(bounds: CGRect(x: 500, y: 30, width: 22, height: 22), forType: .text, withProperties: nil)
    marker.contents = "批注正文"
    marker.userName = groupID
    page.addAnnotation(marker)

    // 写 sidecar
    try SidecarAnnotationWriter(pdfURL: url).writeBack(document: document, to: url)
    let sidecarURL = SidecarAnnotationStorage.sidecarURL(for: url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

    // 重开新文档并从 sidecar 重建
    let reloaded = try XCTUnwrap(PDFDocument(url: url))
    let data = try Data(contentsOf: sidecarURL)
    let pairs = try SidecarAnnotationStorage.annotations(from: data)
    XCTAssertEqual(pairs.count, 2)
    for (pageIndex, annotation) in pairs {
      reloaded.page(at: pageIndex)?.addAnnotation(annotation)
    }
    let annotations = try XCTUnwrap(reloaded.page(at: 0)).annotations
    // /Text 标记加回页面时 PDFKit 会自动伴随一个 Popup（与 App 内创建行为一致）
    let types = annotations.compactMap(\.type).filter { $0 != "Popup" }.sorted()
    XCTAssertEqual(types, ["Highlight", "Text"])
    let restoredMarker = try XCTUnwrap(annotations.first { $0.type == "Text" })
    XCTAssertEqual(restoredMarker.contents, "批注正文")
    XCTAssertEqual(restoredMarker.userName, groupID)
    let restoredHighlight = try XCTUnwrap(annotations.first { $0.type == "Highlight" })
    XCTAssertEqual(restoredHighlight.bounds, CGRect(x: 10, y: 20, width: 100, height: 12))
  }

  @MainActor
  func testWriteBackDoesNotTouchPDF() throws {
    let (url, document) = try makePDFFile()
    let originalData = try Data(contentsOf: url)
    let page = try XCTUnwrap(document.page(at: 0))
    page.addAnnotation(PDFAnnotation(bounds: .zero, forType: .highlight, withProperties: nil))

    try SidecarAnnotationWriter(pdfURL: url).writeBack(document: document, to: url)

    XCTAssertEqual(try Data(contentsOf: url), originalData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
  }

  @MainActor
  func testPopupExcludedFromSidecar() throws {
    let (url, document) = try makePDFFile()
    let page = try XCTUnwrap(document.page(at: 0))
    let popup = PDFAnnotationPopup(bounds: CGRect(x: 0, y: 0, width: 100, height: 60))
    page.addAnnotation(popup)
    let entries = SidecarAnnotationStorage.entries(for: document)
    XCTAssertTrue(entries.isEmpty)
  }

  @MainActor
  func testCorruptSidecarThrows() {
    // Bug 修复 6：解码失败必须抛错（调用方据此提示用户），不得静默吞成空列表
    XCTAssertThrowsError(try SidecarAnnotationStorage.annotations(from: Data([0xFF, 0x00])))
  }

  @MainActor
  func testColorHexRoundTrip() {
    let color = NSColor(red: 0.455, green: 0.78, blue: 0.988, alpha: 1)
    let hex = SidecarAnnotationStorage.hexString(for: color)
    XCTAssertNotNil(hex)
    let restored = SidecarAnnotationStorage.color(for: hex!)
    let rgb = restored!.usingColorSpace(.deviceRGB)!
    XCTAssertEqual(rgb.redComponent, 0.455, accuracy: 0.01)
    XCTAssertEqual(rgb.greenComponent, 0.78, accuracy: 0.01)
    XCTAssertEqual(rgb.blueComponent, 0.988, accuracy: 0.01)
  }

  @MainActor
  func testSidecarModePersistsPerFile() throws {
    // 固定 suite 名 + 用前清场：避免 UUID 随机名在磁盘堆积 plist
    let suite = "SidecarAnnotationTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { removeTestDefaultsSuite(suite, using: defaults) }
    let (url, document) = try makePDFFile()
    let store = PDFAnnotationStore(defaults: defaults)
    store.attach(document: document, url: url)
    XCTAssertFalse(store.isSidecarMode)
    store.setSidecarMode(true)
    XCTAssertTrue(store.isSidecarMode)

    // 新实例（模拟重启）恢复模式
    let reopened = PDFAnnotationStore(defaults: defaults)
    reopened.attach(document: try XCTUnwrap(PDFDocument(url: url)), url: url)
    XCTAssertTrue(reopened.isSidecarMode)
  }

  // MARK: - sidecar 损坏（Bug 修复 6，NFR-5）

  /// 开启只读模式并落一个损坏的 sidecar，返回 (测试 defaults, pdfURL, sidecarURL, 损坏数据)
  @MainActor
  private func makeCorruptSidecarFixture() throws -> (UserDefaults, URL, URL, Data) {
    // 固定 suite 名 + 用前清场：避免 UUID 随机名在磁盘堆积 plist
    let suite = "SidecarAnnotationTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let (url, document) = try makePDFFile()
    let setup = PDFAnnotationStore(defaults: defaults)
    setup.attach(document: document, url: url)
    setup.setSidecarMode(true)
    let sidecarURL = SidecarAnnotationStorage.sidecarURL(for: url)
    let corrupt = Data([0xFF, 0x00])
    try corrupt.write(to: sidecarURL)
    return (defaults, url, sidecarURL, corrupt)
  }

  /// sidecar 损坏：attach 必须经 lastError 上报（不得静默吞成「无标注」），
  /// 且后续写回被抑制——内存标注不完整，写回会用残缺数据覆盖原文件
  @MainActor
  func testCorruptSidecarReportsErrorAndProtectsFile() throws {
    let (defaults, url, sidecarURL, corrupt) = try makeCorruptSidecarFixture()
    defer { removeTestDefaultsSuite("SidecarAnnotationTests", using: defaults) }

    // 重新 attach（模拟重开）触发 sidecar 加载
    let store = PDFAnnotationStore(defaults: defaults)
    let doc = try XCTUnwrap(PDFDocument(url: url))
    store.attach(document: doc, url: url)
    XCTAssertTrue(store.isSidecarMode)
    XCTAssertNotNil(store.lastError, "sidecar 损坏必须经 lastError 上报（NFR-5）")

    // 写回被抑制：标注变更 + flush 后原文件字节不变
    store.add(
      PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 10, height: 10), forType: .highlight, withProperties: nil),
      to: try XCTUnwrap(doc.page(at: 0)))
    store.flushPendingWrites()
    XCTAssertEqual(try Data(contentsOf: sidecarURL), corrupt, "加载失败后不得写回覆盖原 sidecar")
  }

  /// 持续失败只提示一次（attach 随分栏焦点切换反复发生）；修复文件后重开：
  /// 加载成功、提示标志复位、写回恢复
  @MainActor
  func testCorruptSidecarReportsOnceAndRecoversAfterFix() throws {
    let (defaults, url, sidecarURL, _) = try makeCorruptSidecarFixture()
    defer { removeTestDefaultsSuite("SidecarAnnotationTests", using: defaults) }
    // 第二个正常文件（无 sidecar），用于「切走再切回」的重复 attach
    let otherDoc = PDFDocument()
    otherDoc.insert(PDFPage(), at: 0)
    let otherURL = tempDir.appendingPathComponent("b.pdf")
    try XCTUnwrap(otherDoc.dataRepresentation()).write(to: otherURL)

    let store = PDFAnnotationStore(defaults: defaults)
    let docA = try XCTUnwrap(PDFDocument(url: url))
    store.attach(document: docA, url: url)
    XCTAssertNotNil(store.lastError, "首次加载损坏 sidecar 必须提示")

    // 模拟用户关掉弹窗；焦点切走再切回（再次 attach 同一损坏文件）不得重复提示
    store.lastError = nil
    store.attach(document: try XCTUnwrap(PDFDocument(url: otherURL)), url: otherURL)
    XCTAssertNil(store.lastError, "正常文件（无 sidecar）attach 不报错")
    store.attach(document: docA, url: url)
    XCTAssertNil(store.lastError, "同一损坏文件持续失败只提示一次")

    // 修复 sidecar 后重开：加载成功，写回恢复
    let valid = SidecarAnnotationStorage.SidecarFile(
      version: SidecarAnnotationStorage.currentVersion, annotations: [])
    try JSONEncoder().encode(valid).write(to: sidecarURL)
    let fixedDoc = try XCTUnwrap(PDFDocument(url: url))
    store.attach(document: fixedDoc, url: url)
    XCTAssertNil(store.lastError)
    store.add(
      PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 10, height: 10), forType: .highlight, withProperties: nil),
      to: try XCTUnwrap(fixedDoc.page(at: 0)))
    store.flushPendingWrites()
    XCTAssertFalse(store.hasUnsavedChanges, "修复后写回必须恢复")
  }
}
