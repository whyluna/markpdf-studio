import Foundation
import PDFKit

/// 标注写回错误（FR-4.6）
enum AnnotationWriteError: LocalizedError {
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .writeFailed: "PDF 写回失败"
    }
  }
}

/// 标注写回服务（FR-4.6）：把 PDFDocument 写回原文件。
/// 写回前自动创建一次性 `.bak` 备份；原子写入，异常中断不产生半截文件。
/// 协议化（开发规范 §3.2）：测试可注入 mock。
protocol AnnotationWriter {
  func writeBack(document: PDFDocument, to url: URL) throws
}

final class LiveAnnotationWriter: AnnotationWriter {
  private let fm = FileManager.default

  func writeBack(document: PDFDocument, to url: URL) throws {
    // 1. 一次性 .bak：仅首次写回前创建，保留原始文件
    let bakURL = url.appendingPathExtension("bak")
    if !fm.fileExists(atPath: bakURL.path) {
      try fm.copyItem(at: url, to: bakURL)
    }
    // 2. 原子写回：先写临时文件再替换
    let tmpURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).tmp")
    defer { try? fm.removeItem(at: tmpURL) }
    guard document.write(to: tmpURL) else {
      throw AnnotationWriteError.writeFailed
    }
    if let result = try? fm.replaceItemAt(url, withItemAt: tmpURL), result != nil {
      return
    }
    // replaceItemAt 不可用时降级为移动（同卷 rename，仍近原子）
    _ = try? fm.removeItem(at: url)
    try fm.moveItem(at: tmpURL, to: url)
  }
}
