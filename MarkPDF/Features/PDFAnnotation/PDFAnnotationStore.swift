import os
import PDFKit

/// PDF 标注状态中枢（模块 4）：标注工具/颜色状态、文档关联、防抖写回调度（FR-4.6）。
/// 主线程使用（开发规范 §3.2）；标注变更统一走 `markDirty()` → 500ms 防抖原子写回。
@MainActor
final class PDFAnnotationStore: ObservableObject {
  /// 当前 PDF 文件（nil = 无打开文档）
  @Published private(set) var currentFileURL: URL?
  /// 当前选中的标注工具（nil = 仅阅读/选择文本）
  @Published var activeTool: AnnotationKind?
  /// 各标注类型最近用色（FR-4.4；初始为各类型默认色，变更后持久化到 UserDefaults）
  @Published var colorsByKind: [AnnotationKind: AnnotationColor]
  /// 色板当前作用的标注类型（FR-4.4：选中工具时跟随切换）
  @Published var paletteKind: AnnotationKind = .highlight
  /// 有未写回的标注改动
  @Published private(set) var hasUnsavedChanges = false
  /// 最近一次写回错误（视图据此弹 alert 后置回 nil；NFR-5：文件操作异常须用户可感知）
  @Published var lastError: String?
  /// 标注结构版本号：增删改即 +1，驱动列表面板实时同步（FR-4.5）
  @Published private(set) var revision = 0 {
    // 列表缓存唯一刷新点：attach 即时 / 变更防抖后各重扫一次
    didSet { rescanAnnotationItems() }
  }
  /// 标注列表条目缓存（FR-4.5）：仅随 revision 刷新。视图 body 读此缓存——
  /// 全文档重扫含逐标注文本提取，不能随任意 @Published（activeTool/colorsByKind…）
  /// 变化触发的 body 重估而重跑
  @Published private(set) var annotationItemsSnapshot: [AnnotationItem] = []
  /// 全文档重扫（缓存重建）次数（测试钩子：验证重复读缓存、无关 @Published 变化不重扫）
  private(set) var annotationItemsRescanCount = 0

  private var writer: AnnotationWriter
  private let defaults: UserDefaults
  private let debouncer = Debouncer(interval: 0.5)
  /// revision 刷新防抖：批注输入每键都 markDirty，全文档重扫（含逐标注文本提取）
  /// 不能按键频跑；列表最终一致即可
  private let revisionDebouncer = Debouncer(interval: 0.3)
  private weak var document: PDFDocument?
  /// 写回持续失败只提示一次（防抖窗口内反复重试），写回恢复后复位
  private var hasReportedWriteFailure = false

  init(writer: AnnotationWriter = LiveAnnotationWriter(), defaults: UserDefaults = .standard) {
    self.writer = writer
    self.defaults = defaults
    var colors: [AnnotationKind: AnnotationColor] = [:]
    for kind in AnnotationKind.allCases {
      if let raw = defaults.string(forKey: Self.colorKey(for: kind)),
        let saved = AnnotationColor(rawValue: raw)
      {
        colors[kind] = saved
      } else {
        colors[kind] = AnnotationColor.default(for: kind)
      }
    }
    colorsByKind = colors
  }

  private static func colorKey(for kind: AnnotationKind) -> String {
    "annotationColor.\(kind.rawValue)"
  }

  /// 关联当前文档（打开/切换 PDF、分栏焦点切换时调用）。
  /// 替换目标前先落盘旧 (document, url) 的挂起改动：分栏双 PDF 时防止 A 窗标注
  /// 随指向切换写进 B 文档（调用方须保证旧 document 仍有强引用，pdfView.document 在就成立）。
  /// 重复 attach 同一文档是 no-op——焦点认领每次点击都会调用，重跑会无谓 flush、
  /// 全页扫描屏蔽 Popup 并触发标注列表刷新
  func attach(document: PDFDocument, url: URL) {
    guard self.document !== document || currentFileURL != url else { return }
    flushPendingWrites()
    self.document = document
    currentFileURL = url
    // FR-4.7：按文件恢复只读模式与对应写回通道
    let sidecar = Self.persistedSidecarPaths(defaults: defaults).contains(url.path)
    isSidecarMode = sidecar
    writer = sidecar ? SidecarAnnotationWriter(pdfURL: url) : LiveAnnotationWriter()
    if sidecar, let data = try? Data(contentsOf: SidecarAnnotationStorage.sidecarURL(for: url)) {
      // 只读模式：从 sidecar JSON 重建标注到页面
      for (pageIndex, annotation) in SidecarAnnotationStorage.annotations(from: data) {
        guard let page = document.page(at: pageIndex) else { continue }
        page.addAnnotation(annotation)
      }
    }
    hasUnsavedChanges = false
    revision += 1
    // 屏蔽原生 Popup 弹窗：PDFView 点击 /Text 图标会自开 Popup 伴侣窗，
    // 与我们的批注编辑框双开（编辑统一走自己的 popover）
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations where annotation is PDFAnnotationPopup {
        annotation.shouldDisplay = false
      }
    }
  }

  // MARK: - 只读模式（FR-4.7）

  /// 当前文件是否只读标注模式（标注存同名 sidecar JSON，不改 PDF 本体）
  @Published private(set) var isSidecarMode = false

  private static let sidecarPathsKey = "sidecarModePaths"

  private static func persistedSidecarPaths(defaults: UserDefaults) -> Set<String> {
    Set(defaults.stringArray(forKey: sidecarPathsKey) ?? [])
  }

  /// 逐文件切换只读模式（持久化；切换只影响写回目的地，不迁移既有标注）
  func setSidecarMode(_ enabled: Bool) {
    guard let url = currentFileURL, enabled != isSidecarMode else { return }
    // 切换写回通道前先落盘挂起改动（Bug C1 同类）：否则防抖窗口内的变更
    // 会在下一次防抖触发时被写进新目的地
    flushPendingWrites()
    var paths = Self.persistedSidecarPaths(defaults: defaults)
    if enabled {
      paths.insert(url.path)
    } else {
      paths.remove(url.path)
    }
    defaults.set(Array(paths), forKey: Self.sidecarPathsKey)
    isSidecarMode = enabled
    writer = enabled ? SidecarAnnotationWriter(pdfURL: url) : LiveAnnotationWriter()
  }

  // MARK: - 标注变更

  /// 添加标注并调度写回
  func add(_ annotation: PDFAnnotation, to page: PDFPage) {
    page.addAnnotation(annotation)
    markDirty()
  }

  /// 移除标注并调度写回（便签型标注连带移除 Popup 伴侣）
  func remove(_ annotation: PDFAnnotation, from page: PDFPage) {
    if let popup = annotation.popup, popup.page === page {
      page.removeAnnotation(popup)
    }
    page.removeAnnotation(annotation)
    markDirty()
  }

  /// 变更标注属性（颜色等）并调度写回
  func update(_ annotation: PDFAnnotation, mutate: (PDFAnnotation) -> Void) {
    mutate(annotation)
    markDirty()
  }

  /// 记录某类型最近用色并持久化（FR-4.4 记忆）
  func remember(color: AnnotationColor, for kind: AnnotationKind) {
    colorsByKind[kind] = color
    defaults.set(color.rawValue, forKey: Self.colorKey(for: kind))
  }

  // MARK: - 列表快照（FR-4.5）

  /// 全文档标注条目（实时全扫，开销大；视图请改读 annotationItemsSnapshot 缓存）。
  /// 导出等需要当下最新结果的调用方保留此入口——防抖窗口内的变更尚未刷新缓存
  func annotationItems() -> [AnnotationItem] {
    scanAnnotationItems()
  }

  /// 重扫全文档并刷新列表缓存（计数供测试断言缓存复用）
  private func rescanAnnotationItems() {
    annotationItemsRescanCount += 1
    annotationItemsSnapshot = scanAnnotationItems()
  }

  /// 全文档标注条目扫描（同组标注合并，含组内非管理类型成员如批注连接线；
  /// 无组的非管理类型如 Popup 不进列表）
  private func scanAnnotationItems() -> [AnnotationItem] {
    guard let document else { return [] }
    var grouped: [String: [PDFAnnotation]] = [:]
    var singles: [PDFAnnotation] = []
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations {
        if isAnnotationGroupID(annotation.userName) {
          grouped[annotation.userName!, default: []].append(annotation)
        } else if AnnotationKind.of(annotation) != nil {
          singles.append(annotation)
        }
      }
    }
    var items: [AnnotationItem] = []
    for (groupID, annotations) in grouped {
      if let item = makeItem(id: groupID, annotations: annotations) {
        items.append(item)
      }
    }
    for annotation in singles {
      if let item = makeItem(id: "\(ObjectIdentifier(annotation))", annotations: [annotation]) {
        items.append(item)
      }
    }
    return items
  }

  /// 组条目主标注：批注组以标记图标为主（contents = 批注正文，类型显示"批注"），
  /// 否则取首个受管理类型成员
  private func makeItem(id: String, annotations: [PDFAnnotation]) -> AnnotationItem? {
    let primary = annotations.first(where: \.isCommentMarker)
      ?? annotations.first(where: { AnnotationKind.of($0) != nil })
    guard let primary,
      let page = primary.page,
      let document
    else { return nil }
    let kind: AnnotationKind = primary.isCommentMarker
      ? .freeText
      : AnnotationKind.of(primary)!
    // 摘录：拼接各段覆盖文本，规整空白后截断
    let excerpt = annotations
      .compactMap { $0.page?.selection(for: $0.bounds)?.string }
      .joined(separator: " ")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let name = (primary.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return AnnotationItem(
      id: id,
      annotations: annotations,
      kind: kind,
      color: primary.color,
      pageIndex: document.index(for: page),
      excerpt: String(excerpt.prefix(80)),
      name: name
    )
  }

  // MARK: - 写回调度（FR-4.6）

  /// 标注变更统一入口：标记脏并调度 500ms 防抖写回。
  /// hasUnsavedChanges 重复置 true 也会广播 @Published（每键触发全局重渲染），必须拦重
  func markDirty() {
    if !hasUnsavedChanges {
      hasUnsavedChanges = true
    }
    revisionDebouncer.schedule { [weak self] in
      self?.revision += 1
    }
    debouncer.schedule { [weak self] in
      self?.writeBackNow()
    }
  }

  /// 立即写回挂起的改动（切换文件 / 退出前）
  func flushPendingWrites() {
    debouncer.cancel()
    writeBackNow()
  }

  private func writeBackNow() {
    guard hasUnsavedChanges, let document, let url = currentFileURL else { return }
    do {
      try writer.writeBack(document: document, to: url)
      hasUnsavedChanges = false
      hasReportedWriteFailure = false
      Logger.pdf.debug("标注已写回: \(url.lastPathComponent, privacy: .public)")
    } catch {
      Logger.pdf.error("标注写回失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      // 持续失败只提示一次（每次标注变更都会重试），避免弹窗轰炸
      if !hasReportedWriteFailure {
        hasReportedWriteFailure = true
        lastError = "标注写回失败「\(url.lastPathComponent)」：\(error.localizedDescription)"
      }
    }
  }
}
