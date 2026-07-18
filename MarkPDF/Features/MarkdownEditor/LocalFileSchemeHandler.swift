import UniformTypeIdentifiers
import WebKit

/// 本地文件协议处理器（FR-2.3 图片内联显示）。
/// WKWebView 沙盒无法直接读取工作区文件，内核把图片相对路径解析为
/// `markpdf-file:///<绝对路径>`，由本处理器读盘供给。
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "markpdf-file"

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url, url.scheme == Self.scheme else {
      task.didFailWithError(URLError(.badURL))
      return
    }
    // markpdf-file:///abs/path → 本地绝对路径（URL.path 已百分号解码）
    let fileURL = URL(fileURLWithPath: url.path)
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
      task.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
