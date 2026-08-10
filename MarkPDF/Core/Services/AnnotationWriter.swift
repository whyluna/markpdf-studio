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

/// 标注写回服务（FR-4.6）：把 PDFDocument 写回原文件。
/// 写回前自动创建一次性 `.bak` 备份；原子写入，异常中断不产生半截文件。
/// 协议化（开发规范 §3.2）：测试可注入 mock。
///
/// 两段式：序列化（碰 PDFKit，必须主线程）与落盘（纯文件 I/O，可后台串行执行）分开——
/// 全量写回是 O(文件大小)，跑在主线程会在批注编辑结束那一刻卡住 UI 一两秒
protocol AnnotationWriter: Sendable {
  /// 序列化文档为待落盘字节（主线程：PDFKit 对象非线程安全）
  func serialize(document: PDFDocument) throws -> Data
  /// 落盘（只碰文件系统，可在后台串行队列执行）
  func commit(_ data: Data, to url: URL) throws
}

extension AnnotationWriter {
  /// 同步写回（切换文件 / 关窗 / 退出的兜底路径）
  func writeBack(document: PDFDocument, to url: URL) throws {
    try commit(serialize(document: document), to: url)
  }
}

final class LiveAnnotationWriter: AnnotationWriter, @unchecked Sendable {
  private let fm: FileManager

  /// - Parameter fileManager: 可注入子类模拟文件系统失败（降级路径回归测试用）
  init(fileManager: FileManager = .default) {
    self.fm = fileManager
  }

  func serialize(document: PDFDocument) throws -> Data {
    guard let data = document.dataRepresentation() else {
      throw AnnotationWriteError.writeFailed
    }
    return data
  }

  func commit(_ data: Data, to url: URL) throws {
    // 1. 一次性 .bak：仅首次写回前创建，保留原始文件
    let bakURL = url.appendingPathExtension("bak")
    if !fm.fileExists(atPath: bakURL.path) {
      try fm.copyItem(at: url, to: bakURL)
    }
    // 2. 原子写回：先写临时文件再替换
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
