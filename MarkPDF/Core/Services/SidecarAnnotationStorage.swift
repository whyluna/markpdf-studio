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
  struct Entry: Codable, Equatable, Sendable {
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
    /// 四边形点（页坐标，x/y 交替）：外部阅读器建的跨行高亮把多行放在一条标注里，
    /// 只按包围盒重建会摊成一大块，带上原值才能保真
    var quad: [Double]?
  }

  struct SidecarFile: Codable {
    var version: Int
    var annotations: [Entry]
  }

  static let currentVersion = 1

  // MARK: - 序列化（document → entries）

  /// 提取文档中应持久化的标注（排除 Popup 伴侣——创建时自动伴随，无需存储；
  /// 注意 PDFKit 自动创建的伴侣类名是 PDFAnnotation 而非 PDFAnnotationPopup，必须按 type 判）。
  /// - Parameter include: 额外筛选（写回 PDF 本体时只取本应用管理的标注，PDF 自带的
  ///   超链接/表单域原样留在文件里，不经我们的重建流程）
  static func entries(
    for document: PDFDocument,
    include: (PDFAnnotation) -> Bool = { _ in true }
  ) -> [Entry] {
    var entries: [Entry] = []
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else { continue }
      for annotation in page.annotations where !(annotation is PDFAnnotationPopup) {
        guard let type = annotation.type else { continue }
        let subtype = type.hasPrefix("/") ? String(type.dropFirst()) : type
        if subtype == "Popup" { continue }
        guard include(annotation) else { continue }
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
            userName: annotation.userName,
            quad: annotation.quadrilateralPoints?.flatMap {
              [Double($0.pointValue.x), Double($0.pointValue.y)]
            }
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
    // 更新版本的文件按本版格式强解可能静默错位——拒绝并让调用方走「损坏」保护
    //（禁写回防覆盖），留给新版 App 读取
    guard file.version <= currentVersion else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "不支持的 sidecar 版本 \(file.version)（当前 \(currentVersion)）")
      )
    }
    return annotations(from: file.annotations)
  }

  /// entries → 标注（sidecar 恢复与 PDF 写回共用）
  static func annotations(from entries: [Entry]) -> [(page: Int, annotation: PDFAnnotation)] {
    entries.compactMap { entry in
      // 负宽高的畸形 CGRect 直接进 PDFAnnotation 行为未定义（手改/损坏文件防御）
      guard entry.bounds.count == 4, entry.bounds[2] >= 0, entry.bounds[3] >= 0,
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
      // 批注标记只用便签图标一种；不补的话重建出来的图标是空白
      if annotation.isCommentMarker {
        annotation.iconType = .comment
      }
      // 四边形点应为 8 的倍数（每四边形 4 点 × 2 坐标）；非 4 倍数点列行为未定义
      if let quad = entry.quad, quad.count >= 8, quad.count % 8 == 0 {
        annotation.quadrilateralPoints = stride(from: 0, to: quad.count, by: 2).map {
          NSValue(point: NSPoint(x: quad[$0], y: quad[$0 + 1]))
        }
      }
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
final class SidecarAnnotationWriter: AnnotationWriter, @unchecked Sendable {
  private let sidecarURL: URL

  init(pdfURL: URL) {
    sidecarURL = SidecarAnnotationStorage.sidecarURL(for: pdfURL)
  }

  func snapshot(document: PDFDocument) throws -> [SidecarAnnotationStorage.Entry] {
    // 只收本应用管理的标注：PDF 自带的超链接/表单域若收进 sidecar，恢复时会叠加在
    // 本体之上（重建副本动作与外观流丢失），且每轮「打开+写回」线性增长、App 内不可见不可删
    SidecarAnnotationStorage.entries(for: document) { $0.isAppManaged }
  }

  func commit(_ entries: [SidecarAnnotationStorage.Entry], to url: URL) throws {
    let file = SidecarAnnotationStorage.SidecarFile(
      version: SidecarAnnotationStorage.currentVersion,
      annotations: entries
    )
    try JSONEncoder().encode(file).write(to: sidecarURL, options: .atomic)
  }
}
