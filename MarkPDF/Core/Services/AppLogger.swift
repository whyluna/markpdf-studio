import os

extension Logger {
  /// PDF 阅读与标注
  static let pdf = Logger(subsystem: "com.whyluna.markpdf", category: "pdf")
  /// Markdown 编辑器与 Web 内核桥接
  static let editor = Logger(subsystem: "com.whyluna.markpdf", category: "editor")
  /// 工作区与文件树
  static let workspace = Logger(subsystem: "com.whyluna.markpdf", category: "workspace")
}
