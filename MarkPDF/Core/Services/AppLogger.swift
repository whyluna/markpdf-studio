import os

extension Logger {
  /// PDF 阅读与标注
  static let pdf = Logger(subsystem: "com.whyluna.markpdf", category: "pdf")
  /// Markdown 编辑器与 Web 内核桥接
  static let editor = Logger(subsystem: "com.whyluna.markpdf", category: "editor")
  /// 工作区与文件树
  static let workspace = Logger(subsystem: "com.whyluna.markpdf", category: "workspace")
  /// markpdf-file 协议供给（图片等本地资源）
  static let scheme = Logger(subsystem: "com.whyluna.markpdf", category: "scheme")
  /// AI 服务（FR-AI；日志只记 Provider 与状态码，不落请求/响应正文）
  static let ai = Logger(subsystem: "com.whyluna.markpdf", category: "ai")
}
