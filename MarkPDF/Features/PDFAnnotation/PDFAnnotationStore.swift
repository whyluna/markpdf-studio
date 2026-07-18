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

  // MARK: - 写回调度（FR-4.6）

  /// 标注变更统一入口：标记脏并调度 500ms 防抖写回
  func markDirty() {
    hasUnsavedChanges = true
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
