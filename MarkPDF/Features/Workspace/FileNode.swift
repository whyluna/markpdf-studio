import Foundation

/// 工作区文件树节点（FR-1.1）。
/// 树中只保留目录与受支持文件（Markdown / PDF / 图片），其余在扫描阶段过滤。
struct FileNode: Identifiable, Hashable {
  /// 文件类别
  enum Kind: String, Hashable {
    case folder
    case markdown
    case pdf
    case image
    case other
  }

  /// 以文件 URL 作为稳定身份（同一路径即同一节点）
  let id: URL
  let name: String
  let kind: Kind
  /// 目录的子节点（已过滤、排序）；文件为 nil
  let children: [FileNode]?

  var isFolder: Bool { children != nil }

  init(id: URL, name: String, kind: Kind, children: [FileNode]? = nil) {
    self.id = id
    self.name = name
    self.kind = kind
    self.children = children
  }

  /// 按扩展名归类；目录由调用方传入 isDirectory 判定
  static func kind(for url: URL, isDirectory: Bool) -> Kind {
    if isDirectory { return .folder }
    switch url.pathExtension.lowercased() {
    case "md", "markdown", "mdown", "mkd":
      return .markdown
    case "pdf":
      return .pdf
    case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp":
      return .image
    default:
      return .other
    }
  }

  /// SF Symbols 图标
  var iconName: String {
    switch kind {
    case .folder: return "folder.fill"
    case .markdown: return "doc.text"
    case .pdf: return "doc.richtext"
    case .image: return "photo"
    case .other: return "doc"
    }
  }

  // Hashable 仅按路径判定：避免整棵子树参与比较/哈希（扫描结果可能很大）
  static func == (lhs: FileNode, rhs: FileNode) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
