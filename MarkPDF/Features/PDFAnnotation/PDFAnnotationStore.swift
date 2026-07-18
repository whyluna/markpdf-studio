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
  /// 标注结构版本号：增删改即 +1，驱动列表面板实时同步（FR-4.5）
  @Published private(set) var revision = 0

  private let writer: AnnotationWriter
  private let defaults: UserDefaults
  private let debouncer = Debouncer(interval: 0.5)
  private weak var document: PDFDocument?

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

  /// 关联当前文档（打开/切换 PDF 时调用）
  func attach(document: PDFDocument, url: URL) {
    flushPendingWrites()
    self.document = document
    currentFileURL = url
    hasUnsavedChanges = false
    revision += 1
  }

  // MARK: - 标注变更

  /// 添加标注并调度写回
  func add(_ annotation: PDFAnnotation, to page: PDFPage) {
    page.addAnnotation(annotation)
    markDirty()
  }

  /// 移除标注并调度写回
  func remove(_ annotation: PDFAnnotation, from page: PDFPage) {
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

  /// 全文档标注条目（同组标注合并；跳过 Popup/链接等非面板管理类型）
  func annotationItems() -> [AnnotationItem] {
    guard let document else { return [] }
    var grouped: [String: [PDFAnnotation]] = [:]
    var singles: [PDFAnnotation] = []
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations where AnnotationKind.of(annotation) != nil {
        if let groupID = annotation.userName, !groupID.isEmpty {
          grouped[groupID, default: []].append(annotation)
        } else {
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

  private func makeItem(id: String, annotations: [PDFAnnotation]) -> AnnotationItem? {
    guard let first = annotations.first,
      let kind = AnnotationKind.of(first),
      let page = first.page,
      let document
    else { return nil }
    // 摘录：拼接各段覆盖文本，规整空白后截断
    let excerpt = annotations
      .compactMap { $0.page?.selection(for: $0.bounds)?.string }
      .joined(separator: " ")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let name = (first.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return AnnotationItem(
      id: id,
      annotations: annotations,
      kind: kind,
      color: first.color,
      pageIndex: document.index(for: page),
      excerpt: String(excerpt.prefix(80)),
      name: name
    )
  }

  // MARK: - 写回调度（FR-4.6）

  /// 标注变更统一入口：标记脏并调度 500ms 防抖写回
  func markDirty() {
    hasUnsavedChanges = true
    revision += 1
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
      Logger.pdf.debug("标注已写回: \(url.lastPathComponent, privacy: .public)")
    } catch {
      Logger.pdf.error("标注写回失败 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }
}
