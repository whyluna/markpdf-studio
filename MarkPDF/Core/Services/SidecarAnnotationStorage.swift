import Foundation
import PDFKit

/// 只读模式 sidecar 存储（FR-4.7）：标注不写入 PDF 本体，序列化到同名 `.json` 附属文件。
/// 同名规则：`论文.pdf` → `论文.json`（PRD 名词约定：与原文件同名的 .json 附属文件）。
enum SidecarAnnotationStorage {
  /// sidecar 文件地址（与原 PDF 同目录同名、扩展名换 json）
  static func sidecarURL(for pdfURL: URL) -> URL {
    pdfURL.deletingPathExtension().appendingPathExtension("json")
  }

  /// 单条标注的序列化形态
  struct Entry: Codable, Equatable {
    /// 0 起页码
    var page: Int
    /// PDFAnnotation subtype（"Highlight" / "Text" 等）
    var type: String
    /// [x, y, width, height]
    var bounds: [Double]
    /// 十六进制 RGB（"FFD43B"）
    var color: String?
    var contents: String?
    /// 组 ID（本应用生成的 UUID 串）
    var userName: String?
  }

  struct SidecarFile: Codable {
    var version: Int
    var annotations: [Entry]
  }

  static let currentVersion = 1

  // MARK: - 序列化（document → entries）

  /// 提取文档中应持久化的标注（排除 Popup 伴侣——创建时自动伴随，无需存储；
  /// 注意 PDFKit 自动创建的伴侣类名是 PDFAnnotation 而非 PDFAnnotationPopup，必须按 type 判）
  static func entries(for document: PDFDocument) -> [Entry] {
    var entries: [Entry] = []
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations where !(annotation is PDFAnnotationPopup) {
        guard let type = annotation.type else { continue }
        let subtype = type.hasPrefix("/") ? String(type.dropFirst()) : type
        if subtype == "Popup" { continue }
        let bounds = annotation.bounds
        entries.append(
          Entry(
            page: pageIndex,
            type: subtype,
            bounds: [
              Double(bounds.origin.x), Double(bounds.origin.y),
              Double(bounds.width), Double(bounds.height),
            ],
            color: hexString(for: annotation.color),
            contents: annotation.contents,
            userName: annotation.userName
          ))
      }
    }
    return entries
  }

  // MARK: - 反序列化（data → annotations）

  /// 从 sidecar 数据重建标注（返回 (页码, 标注) 对，按页分组插入）。
  /// 解码失败抛错（Bug 修复 6）：损坏的 sidecar 不得静默吞成空列表——
  /// 那会让用户标注无声消失（违反 NFR-5），调用方需据此提示并保护原文件
  static func annotations(from data: Data) throws -> [(page: Int, annotation: PDFAnnotation)] {
    let file = try JSONDecoder().decode(SidecarFile.self, from: data)
    return file.annotations.compactMap { entry in
      guard entry.bounds.count == 4,
        let subtype = PDFAnnotationSubtype(rawValue: "/\(entry.type)") as PDFAnnotationSubtype?
      else { return nil }
      let bounds = CGRect(
        x: entry.bounds[0], y: entry.bounds[1],
        width: entry.bounds[2], height: entry.bounds[3]
      )
      let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
      if let hex = entry.color, let color = color(for: hex) {
        annotation.color = color
      }
      annotation.contents = entry.contents
      annotation.userName = entry.userName
      return (entry.page, annotation)
    }
  }

  // MARK: - 颜色编解码

  static func hexString(for color: NSColor) -> String? {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "%02X%02X%02X", r, g, b)
  }

  static func color(for hex: String) -> NSColor? {
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return NSColor(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }
}

/// 只读模式写回服务（FR-4.7）：标注写 sidecar JSON（原子写），PDF 本体不动、无 .bak。
final class SidecarAnnotationWriter: AnnotationWriter {
  private let sidecarURL: URL

  init(pdfURL: URL) {
    sidecarURL = SidecarAnnotationStorage.sidecarURL(for: pdfURL)
  }

  func writeBack(document: PDFDocument, to url: URL) throws {
    let file = SidecarAnnotationStorage.SidecarFile(
      version: SidecarAnnotationStorage.currentVersion,
      annotations: SidecarAnnotationStorage.entries(for: document)
    )
    let data = try JSONEncoder().encode(file)
    try data.write(to: sidecarURL, options: .atomic)
  }
}
