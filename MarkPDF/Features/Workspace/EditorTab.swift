import Foundation

/// 编辑器标签（FR-1.4）：一个打开的文件或草稿。
struct EditorTab: Equatable, Identifiable {
  /// 文件 URL（草稿为 nil）
  let url: URL?
  /// 文件类别（markdown / pdf / image）
  let kind: FileNode.Kind
  /// 草稿标签的身份
  private let uuid = UUID()

  /// 文件标签以路径为身份（同路径同标签）；草稿以 UUID 为身份
  var id: String { url?.path ?? uuid.uuidString }
  var title: String { url?.lastPathComponent ?? String(localized: "未命名") }
  var isDraft: Bool { url == nil }

  /// SF Symbols 图标（与文件树一致）
  var iconName: String {
    switch kind {
    case .markdown: "doc.text"
    case .pdf: "doc.richtext"
    case .image: "photo"
    default: "doc"
    }
  }
}
