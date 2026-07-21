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
  /// 待跳转页（FR-6.2 全文搜索命中跳转；PDFReaderView 创建后消费一次）
  var pendingPage: Int?
  /// 跳转后是否闪烁页面（FR-5.3 回链跳转短暂高亮）
  var pendingFlash = false
  /// 当前是否有文本选区（FR-5.2 菜单启用条件；PDFReaderView 监听选区通知回写）
  @Published var hasSelection = false

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
    if findMatches.isEmpty { return "无结果" }
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
