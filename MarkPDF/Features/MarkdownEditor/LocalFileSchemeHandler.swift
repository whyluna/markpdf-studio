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
    let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    return roots.contains { root in
      let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
      return path == rootPath || path.hasPrefix(rootPath + "/")
    }
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
