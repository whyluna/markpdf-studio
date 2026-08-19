import UniformTypeIdentifiers
import WebKit
import os

/// 本地文件协议处理器（FR-2.3 图片内联显示）。
/// WKWebView 沙盒无法直接读取工作区文件，内核把图片相对路径解析为
/// `markpdf-file:///<绝对路径>`，由本处理器读盘供给。
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "markpdf-file"

  /// 允许供给的根目录（工作区根 / 当前文档目录），惰性闭包随宿主取值。
  /// 路径围栏：不可信 md 里的 `![](/etc/hosts)`、`![](../../outside)` 不能经本协议
  /// 把工作区外文件读进 Web 进程（纵深防御——沙盒之外再设一道）
  var allowedRoots: () -> [URL] = { [] }

  /// 路径是否在任一允许根之内（纯函数可单测）：标准化 + 符号链接归一后按路径组件边界判定
  static func isAllowed(_ fileURL: URL, roots: [URL]) -> Bool {
    let path = resolvedPath(fileURL)
    return roots.contains { root in
      let rootPath = resolvedPath(root)
      return path == rootPath || path.hasPrefix(rootPath + "/")
    }
  }

  /// 符号链接归一的稳定口径：目标文件可能尚不存在（如仅被引用未落盘的图片），
  /// 新版 macOS 的 resolvingSymlinksInPath 对「存在的符号链接 + 不存在的尾段」
  /// 不再解析链接段（实测 darwin 25.6 回归）——退到最近的存在祖先解析后拼回尾巴
  static func resolvedPath(_ fileURL: URL) -> String {
    let standardized = fileURL.standardizedFileURL
    var current = standardized
    var tail: [String] = []
    while current.path != "/" && !FileManager.default.fileExists(atPath: current.path) {
      tail.insert(current.lastPathComponent, at: 0)
      current = current.deletingLastPathComponent()
    }
    let base = current.standardizedFileURL.resolvingSymlinksInPath().path
    guard !tail.isEmpty else { return base }
    return tail.reduce(into: base) { $0 += "/" + $1 }
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url, url.scheme == Self.scheme else {
      task.didFailWithError(URLError(.badURL))
      return
    }
    // markpdf-file:///abs/path → 本地绝对路径（URL.path 已百分号解码）
    let fileURL = URL(fileURLWithPath: url.path)
    guard Self.isAllowed(fileURL, roots: allowedRoots()) else {
      Logger.scheme.error("markpdf-file 围栏拒绝: \(fileURL.path, privacy: .public)")
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    do {
      let data = try Data(contentsOf: fileURL)
      let mime = UTType(filenameExtension: fileURL.pathExtension)?
        .preferredMIMEType ?? "application/octet-stream"
      let response = URLResponse(
        url: url,
        mimeType: mime,
        expectedContentLength: data.count,
        textEncodingName: nil
      )
      task.didReceive(response)
      task.didReceive(data)
      task.didFinish()
    } catch {
      Logger.scheme.error("markpdf-file 读盘失败: \(fileURL.path, privacy: .public) → \(error.localizedDescription, privacy: .public)")
      task.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
