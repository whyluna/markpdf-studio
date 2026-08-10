import Foundation
import PDFKit

/// 标注写回错误（FR-4.6）
enum AnnotationWriteError: LocalizedError {
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .writeFailed: String(localized: "PDF 写回失败")
    }
  }
}

/// 标注写回服务（FR-4.6）：把标注写回原文件。
/// 写回前自动创建一次性 `.bak` 备份；原子写入，异常中断不产生半截文件。
/// 协议化（开发规范 §3.2）：测试可注入 mock。
///
/// 两段式：`snapshot` 在主线程把标注收成纯数据（毫秒级），`commit` 在后台串行队列
/// 自己开一份私有文档落盘。这么分是因为 `PDFDocument.dataRepresentation()` 会把每一页
/// 重新绘制一遍（采样实锤 0.4~1.5s，一半耗在嵌入字体按 glyph 名查找抛 C++ 异常的栈展开），
/// 放主线程就是每次标注动作后的整秒卡顿；而 PDFKit 对象不能跨线程共享，
/// 后台必须用主线程从不触碰的独立对象图
protocol AnnotationWriter: Sendable {
  /// 主线程：把文档里需要落盘的标注收成纯数据
  func snapshot(document: PDFDocument) throws -> [SidecarAnnotationStorage.Entry]
  /// 后台串行队列：按快照落盘
  func commit(_ entries: [SidecarAnnotationStorage.Entry], to url: URL) throws
}

extension AnnotationWriter {
  /// 同步写回（切换文件 / 关窗 / 退出的兜底路径）
  func writeBack(document: PDFDocument, to url: URL) throws {
    try commit(snapshot(document: document), to: url)
  }
}

final class LiveAnnotationWriter: AnnotationWriter, @unchecked Sendable {
  private let fm: FileManager

  /// - Parameter fileManager: 可注入子类模拟文件系统失败（降级路径回归测试用）
  init(fileManager: FileManager = .default) {
    self.fm = fileManager
  }

  /// 只取本应用管理的标注：PDF 自带的超链接/表单域/图形标注原样留在文件里，
  /// 不经重建流程（重建只保 bounds/颜色/内容，会丢掉它们的动作与外观流）
  func snapshot(document: PDFDocument) throws -> [SidecarAnnotationStorage.Entry] {
    SidecarAnnotationStorage.entries(for: document) { $0.isAppManaged }
  }

  func commit(_ entries: [SidecarAnnotationStorage.Entry], to url: URL) throws {
    // 1. 一次性 .bak：仅首次写回前创建，保留原始文件
    let bakURL = url.appendingPathExtension("bak")
    if !fm.fileExists(atPath: bakURL.path) {
      try fm.copyItem(at: url, to: bakURL)
    }
    // 2. 私有副本：从磁盘现状重开一份，摘掉上次写进去的本应用标注后按快照重放。
    // 「先摘再放」保证反复写回不重复堆积，删除也能落地；其余标注（超链接等）原样保留
    guard let document = PDFDocument(url: url) else {
      throw AnnotationWriteError.writeFailed
    }
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations where annotation.isAppManaged {
        page.removeAnnotation(annotation)
      }
      // 摘完后没有任何标注再引用的 Popup 伴侣即孤立（批注标记连带产生），一并清掉
      let referenced = Set(page.annotations.compactMap { $0.popup.map(ObjectIdentifier.init) })
      for annotation in page.annotations
      where annotation.isPopup && !referenced.contains(ObjectIdentifier(annotation)) {
        page.removeAnnotation(annotation)
      }
    }
    for (pageIndex, annotation) in SidecarAnnotationStorage.annotations(from: entries) {
      document.page(at: pageIndex)?.addAnnotation(annotation)
    }
    guard let data = document.dataRepresentation() else {
      throw AnnotationWriteError.writeFailed
    }
    // 3. 原子写回：先写临时文件再替换
    let tmpURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).tmp")
    do {
      try data.write(to: tmpURL)
    } catch {
      try? fm.removeItem(at: tmpURL)  // 清理可能的半截临时文件
      throw error
    }
    if let result = try? fm.replaceItemAt(url, withItemAt: tmpURL), result != nil {
      return
    }
    // replaceItemAt 不可用时降级为移动（同卷 rename，仍近原子）。
    // 其失败后 tmp 状态未定义（可能被消耗或留下损坏文件，探针+回归测试实锤）——降级前总是重写；
    // moveItem 失败必须保留 tmp：原文件可能已被移除，tmp 是唯一含最新标注的完整副本
    //（若此处清理 tmp，仅剩的 .bak 是无标注原件，标注会全部丢失）
    try data.write(to: tmpURL)
    _ = try? fm.removeItem(at: url)
    try fm.moveItem(at: tmpURL, to: url)
  }
}
