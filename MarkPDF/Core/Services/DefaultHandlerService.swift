import AppKit
import UniformTypeIdentifiers
import os

/// 默认打开方式查询/设置的系统接口（可注入 fake 供单测）
protocol DefaultHandlerProviding {
  func defaultHandlerURL(for type: UTType) -> URL?
  func setDefaultHandler(appURL: URL, for type: UTType, completion: @escaping (Error?) -> Void)
}

struct LiveDefaultHandlerProvider: DefaultHandlerProviding {
  func defaultHandlerURL(for type: UTType) -> URL? {
    NSWorkspace.shared.urlForApplication(toOpen: type)
  }

  func setDefaultHandler(appURL: URL, for type: UTType, completion: @escaping (Error?) -> Void) {
    NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
      DispatchQueue.main.async { completion(error) }
    }
  }
}

/// 「设为默认打开应用」（设置 → 通用）：开关反映系统当前真实状态——
/// 打开 = 调 LaunchServices 设默认；用户在 Finder 改走后开关自动显示关闭；
/// macOS 无「取消默认」概念，关闭动作为无操作（刷新回弹）。
@MainActor
final class DefaultHandlerService: ObservableObject {
  enum FileKind {
    case markdown
    case pdf
  }

  @Published private(set) var isDefaultMarkdown = false
  @Published private(set) var isDefaultPDF = false

  /// Markdown 经典 UTI（多数系统已注册；未注册时退回扩展名推导）
  static let markdownType = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md")!
  static let pdfType = UTType.pdf

  private let provider: DefaultHandlerProviding
  private let appBundleID: String
  private let appURL: URL

  init(
    provider: DefaultHandlerProviding = LiveDefaultHandlerProvider(),
    appBundleID: String = Bundle.main.bundleIdentifier ?? "com.whyluna.markpdf",
    appURL: URL = Bundle.main.bundleURL
  ) {
    self.provider = provider
    self.appBundleID = appBundleID
    self.appURL = appURL
  }

  /// 重查系统当前默认（设置页出现时 + 设置完成后；Finder 侧变更由此感知）
  func refresh() {
    isDefaultMarkdown = isCurrentDefault(for: Self.markdownType)
    isDefaultPDF = isCurrentDefault(for: Self.pdfType)
  }

  func setAsDefault(for kind: FileKind) {
    let type = kind == .markdown ? Self.markdownType : Self.pdfType
    provider.setDefaultHandler(appURL: appURL, for: type) { [weak self] error in
      if let error {
        Logger.workspace.error("设置默认打开应用失败: \(error.localizedDescription, privacy: .public)")
      }
      self?.refresh()
    }
  }

  private func isCurrentDefault(for type: UTType) -> Bool {
    guard let handler = provider.defaultHandlerURL(for: type) else { return false }
    // 按 bundle id 判定（比 URL 相等稳：App 移动位置/多副本仍正确）
    return Bundle(url: handler)?.bundleIdentifier == appBundleID
  }
}
