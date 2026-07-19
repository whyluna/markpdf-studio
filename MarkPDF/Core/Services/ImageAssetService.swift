import Foundation
import os

/// 图片资产存储（FR-2.5）：粘贴/拖拽的图片写入工作区 `assets/`，返回相对 md 的链接路径。
protocol ImageAssetService {
  /// 保存图片数据；返回插入 Markdown 的相对路径（md 目录 → assets 文件）
  func save(
    data: Data,
    suggestedName: String?,
    mime: String?,
    workspaceRoot: URL,
    documentDir: URL
  ) throws -> String
}

final class LiveImageAssetService: ImageAssetService {
  private let fileManager = FileManager.default

  func save(
    data: Data,
    suggestedName: String?,
    mime: String?,
    workspaceRoot: URL,
    documentDir: URL
  ) throws -> String {
    let assetsDir = workspaceRoot.appendingPathComponent("assets", isDirectory: true)
    try fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)

    let ext = Self.extensionFor(mime: mime, suggestedName: suggestedName)
    let base = Self.sanitizedBaseName(suggestedName: suggestedName)
    var candidate = assetsDir.appendingPathComponent("\(base).\(ext)")
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = assetsDir.appendingPathComponent("\(base)-\(suffix).\(ext)")
      suffix += 1
    }
    // 原子写盘（开发规范 §10）
    try data.write(to: candidate, options: .atomic)
    Logger.editor.debug("图片已存入 assets: \(candidate.lastPathComponent, privacy: .public)")
    return MarkdownImageLinkRewriter.relativePath(from: documentDir, to: candidate)
  }

  /// 扩展名：优先 mime，其次来源文件名，兜底 png
  static func extensionFor(mime: String?, suggestedName: String?) -> String {
    switch mime?.lowercased() {
    case "image/png": return "png"
    case "image/jpeg": return "jpg"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/svg+xml": return "svg"
    case "image/heic": return "heic"
    case "image/tiff": return "tiff"
    case "image/bmp": return "bmp"
    default: break
    }
    if let ext = suggestedName.map({ ($0 as NSString).pathExtension }),
      !ext.isEmpty
    {
      return ext.lowercased()
    }
    return "png"
  }

  /// 文件名主体：用来源文件名（如剪贴板的 image.png → image），否则按时间戳生成
  static func sanitizedBaseName(suggestedName: String?) -> String {
    let raw = suggestedName.map { ($0 as NSString).deletingPathExtension } ?? ""
    let cleaned =
      raw
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
    if !cleaned.isEmpty {
      return cleaned
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "pasted-\(formatter.string(from: Date()))"
  }
}
