import Foundation
import PDFKit

/// 可缩放视图状态协议（PDF / 图片缩放命令路由）
@MainActor
protocol ZoomTarget {
  func zoomIn()
  func zoomOut()
  func resetZoom()
}

/// PDF 阅读状态（FR-3.1/3.2）：页码、缩放；Scene 级持有。
@MainActor
final class PDFReaderStore: ObservableObject, ZoomTarget {
  /// 当前页（1 起；0 = 无文档）
  @Published var currentPage = 0
  /// 总页数
  @Published var pageCount = 0
  /// 缩放倍率（1.0 = 100%）
  @Published var scale: CGFloat = 1.0
  /// 当前 PDFView 实例（弱引用，供缩略图/大纲/书签跳转共享；非发布属性）
  weak var pdfView: PDFView?
  /// 待跳转页（FR-6.2 全文搜索 / FR-5.3 回链）：携带目标文件 URL——分栏双 PDF 时
  /// 只有目标文档所在视图可消费（否则先挂载文档的视图会抢跳到自己文档的第 N 页）
  var pendingJump: (url: URL, page: Int)?
  /// 跳转后是否闪烁页面（FR-5.3 回链跳转短暂高亮；随 pendingJump 一并消费）
  var pendingFlash = false
  /// 当前是否有文本选区（FR-5.2 菜单启用条件；PDFReaderView 监听选区通知回写）
  @Published var hasSelection = false
  /// 最近一次文档解析失败信息（Bug 修复 3；视图据此展示占位 + 重试按钮，NFR-5 用户可感知）
  @Published var lastError: String?

  static let minScale: CGFloat = 0.5
  static let maxScale: CGFloat = 4.0
  static let step: CGFloat = 0.25

  /// 夹取到 FR-3.2 范围（50%–400%）
  static func clamped(_ value: CGFloat) -> CGFloat {
    min(max(value, minScale), maxScale)
  }

  func zoomIn() {
    scale = Self.clamped(scale + Self.step)
  }

  func zoomOut() {
    scale = Self.clamped(scale - Self.step)
  }

  func resetZoom() {
    scale = 1.0
  }

  /// 跳转到指定页（FR-3.3；1 起）
  func goTo(page: Int) {
    guard let pdfView, let doc = pdfView.document,
      page >= 1, page <= doc.pageCount,
      let target = doc.page(at: page - 1)
    else { return }
    pdfView.go(to: target)
  }

  /// 跳转到文档大纲目标位置（FR-3.3）
  func go(to destination: PDFDestination) {
    pdfView?.go(to: destination)
  }

  /// 消费指向 url 的待跳转页：仅目标文档所在视图可消费（URL 标准化比较），
  /// 匹配时连同闪烁标记一并取出；不匹配则原样保留，等目标视图来取
  func consumePendingJump(for url: URL) -> (page: Int, flash: Bool)? {
    guard let jump = pendingJump,
      jump.url.standardizedFileURL == url.standardizedFileURL
    else { return nil }
    pendingJump = nil
    let flash = pendingFlash
    pendingFlash = false
    return (jump.page, flash)
  }

  // MARK: - 文档切换 / 加载失败

  /// 切换文档时重置会话状态（Bug 修复 1/2）：
  /// - 查找状态整体复位：findMatches 持有旧文档的 PDFSelection，不清理则切文档后
  ///   ⌘G/回车会把旧 selection setCurrentSelection 到新文档（行为未定义），查找栏还显示旧命中数；
  /// - 缩放归位 100%：避免旧文档倍率（如 2.0）在加载窗口期经 updateNSView 误关 autoScales，
  ///   新文档失去自适应宽度（有存档缩放时由加载完成后的位置恢复重新设置）
  func resetForDocumentSwitch() {
    closeFindBar()
    scale = 1.0
  }

  /// 上报文档解析失败（Bug 修复 3）：重试/再次加载成功前由视图层占位展示
  func reportLoadFailure(for url: URL) {
    lastError = String(localized: "无法打开 PDF「\(url.lastPathComponent)」：文件可能已损坏或格式不受支持")
  }

  // MARK: - 页内搜索（FR-3.4）

  /// 查找栏是否可见
  @Published var isFindBarVisible = false
  /// ⌘F 聚焦请求令牌：每次按 ⌘F 递增，查找栏据此重新聚焦输入框（已打开时再按也回焦）
  @Published var findFocusRequest = 0
  /// 搜索词（变更后 300ms 防抖执行搜索）
  @Published var findQuery = "" {
    didSet {
      findDebouncer.schedule { [weak self] in
        self?.performFind()
      }
    }
  }
  /// 全部命中
  @Published private(set) var findMatches: [PDFSelection] = []
  /// 当前命中下标
  @Published private(set) var currentMatchIndex = 0

  private let findDebouncer = Debouncer(interval: 0.3)

  /// 计数文本：`k / n`；无查询为空，无结果显示提示
  var matchCountText: String {
    if findQuery.isEmpty { return "" }
    if findMatches.isEmpty { return String(localized: "无结果") }
    return "\(currentMatchIndex + 1) / \(findMatches.count)"
  }

  /// 显示查找栏并请求聚焦（⌘F 入口）：已打开时再次调用也会让输入框重新聚焦（FR-3.4）
  func presentFindBar() {
    isFindBarVisible = true
    findFocusRequest += 1
  }

  func performFind() {
    guard let doc = pdfView?.document, !findQuery.isEmpty else {
      findMatches = []
      pdfView?.highlightedSelections = nil
      return
    }
    findMatches = doc.findString(findQuery, withOptions: [.caseInsensitive])
    currentMatchIndex = 0
    pdfView?.highlightedSelections = findMatches
    goToCurrentMatch()
  }

  func findNext() {
    guard !findMatches.isEmpty else { return }
    currentMatchIndex = (currentMatchIndex + 1) % findMatches.count
    goToCurrentMatch()
  }

  func findPrevious() {
    guard !findMatches.isEmpty else { return }
    currentMatchIndex = (currentMatchIndex - 1 + findMatches.count) % findMatches.count
    goToCurrentMatch()
  }

  func closeFindBar() {
    isFindBarVisible = false
    findDebouncer.cancel()
    findQuery = ""
    findMatches = []
    currentMatchIndex = 0
    pdfView?.highlightedSelections = nil
    pdfView?.setCurrentSelection(nil, animate: false)
  }

  private func goToCurrentMatch() {
    guard findMatches.indices.contains(currentMatchIndex) else { return }
    let selection = findMatches[currentMatchIndex]
    pdfView?.setCurrentSelection(selection, animate: true)
    // 滚动到命中词的精确位置：放大后命中词可能在当前视口外（同页下半部），go(to:page) 只对齐页顶不够
    pdfView?.go(to: selection)
  }
}
