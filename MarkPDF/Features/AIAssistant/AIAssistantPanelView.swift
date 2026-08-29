import AppKit
import SwiftUI

/// 原生会话滚动容器桥接：接管 SwiftUI List 底层 NSOutlineView 的行高查询。
/// SwiftUI 的自动行高只在 cell 物化后才准确，长会话会先用错误估值绘制滚动条，
/// 随滚动不断改总高。代理对全部消息使用同步轻量高度模型，建立一次性完整高度表；
/// cell 仍由 SwiftUI 仅渲染视口行，拖宽性能不退回全量 VStack。
@MainActor
final class AITranscriptScrollCoordinator: ObservableObject {
  private enum ResizeAnchor {
    case bottom
    case row(index: Int, offset: CGFloat)
    case absoluteY(CGFloat)
  }

  weak var scrollView: NSScrollView?
  private var messages: [AIChatStore.ChatMessage] = []
  private var sealedSets: [AIChangeStore.SealedChangeSet] = []
  private weak var changeStore: AIChangeStore?
  private let delegateProxy = AITranscriptTableDelegateProxy()
  private var resizeAnchor: ResizeAnchor?
  private var layoutScheduled = false
  private var finishAfterLayout = false
  private var resizeGeneration = 0
  private var scrollWheelMonitor: Any?

  func attach(_ scrollView: NSScrollView?) {
    guard self.scrollView !== scrollView else { return }
    restoreOriginalTableDelegate()
    removeScrollWheelMonitor()
    self.scrollView = scrollView
    guard scrollView != nil else {
      resizeAnchor = nil
      layoutScheduled = false
      finishAfterLayout = false
      return
    }
    ensureHeightDelegateInstalled()
    refreshHeightMap(preserving: nil)
  }

  func updateContent(
    messages: [AIChatStore.ChatMessage],
    changeStore: AIChangeStore
  ) {
    let referenced = Set(messages.compactMap(\.changeSetID))
    let nextSets = changeStore.sealedSets.filter { referenced.contains($0.id) }
    guard messages != self.messages || nextSets != sealedSets || self.changeStore !== changeStore else {
      ensureHeightDelegateInstalled()
      return
    }
    self.messages = messages
    sealedSets = nextSets
    self.changeStore = changeStore
    delegateProxy.update(messages: messages, changeStore: changeStore)
    ensureHeightDelegateInstalled()
    let generation = resizeGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self, generation == self.resizeGeneration else { return }
      let anchor = self.scrollView.map(self.captureAnchor(in:))
      self.refreshHeightMap(preserving: anchor)
    }
  }

  private func installScrollWheelMonitor() {
    guard scrollWheelMonitor == nil else { return }
    // 本地事件监听发生在 NSScrollView 消费滚轮之前，只负责取消待处理锚定；
    // 不读布局、不写滚动位置，让同一个滚轮事件零等待地继续分发。
    scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      self?.userWillScroll(event)
      return event
    }
  }

  func beginResize() {
    guard let scrollView else {
      resizeAnchor = nil
      return
    }
    resizeGeneration += 1
    layoutScheduled = false
    finishAfterLayout = false
    resizeAnchor = captureAnchor(in: scrollView)
    installScrollWheelMonitor()
  }

  /// 列宽已经按显示帧发布；下一轮主队列在同一帧批量读取/写入行高与锚点。
  /// 任务会合并，因此同一显示帧至多触发一次表格布局。
  func widthDidChange() {
    scheduleLayout()
  }

  func endResize() {
    guard resizeAnchor != nil else {
      removeScrollWheelMonitor()
      return
    }
    // mouseUp 不创建新任务。若最终宽度帧仍在队列里，由那一帧收尾；
    // 否则上一帧已经稳定，直接结束即可。
    if layoutScheduled {
      finishAfterLayout = true
    } else {
      resizeAnchor = nil
      removeScrollWheelMonitor()
    }
  }

  private func scheduleLayout() {
    guard resizeAnchor != nil, !layoutScheduled else { return }
    layoutScheduled = true
    let generation = resizeGeneration
    DispatchQueue.main.async { [weak self] in
      self?.applyWidthFrame(generation: generation)
    }
  }

  private func applyWidthFrame(generation: Int) {
    guard generation == resizeGeneration, let anchor = resizeAnchor, let scrollView else { return }
    layoutScheduled = false
    ensureHeightDelegateInstalled()
    refreshHeightMap(preserving: nil)
    apply(anchor, in: scrollView)

    if finishAfterLayout {
      finishAfterLayout = false
      resizeAnchor = nil
      removeScrollWheelMonitor()
    }
  }

  private func apply(_ anchor: ResizeAnchor, in scrollView: NSScrollView) {
    guard let documentView = scrollView.documentView else { return }
    let clipView = scrollView.contentView
    let minY = documentView.bounds.minY
    let maxY = max(documentView.bounds.maxY - clipView.bounds.height, minY)
    let targetY: CGFloat
    switch anchor {
    case .bottom:
      targetY = maxY
    case .absoluteY(let y):
      targetY = min(max(y, minY), maxY)
    case .row(let index, let offset):
      guard let tableView = Self.tableView(in: documentView), tableView.numberOfRows > 0 else { return }
      let row = min(max(index, 0), tableView.numberOfRows - 1)
      let rowRect = tableView.convert(tableView.rect(ofRow: row), to: documentView)
      targetY = min(max(rowRect.minY + min(max(offset, 0), rowRect.height), minY), maxY)
    }
    clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
    scrollView.reflectScrolledClipView(clipView)
  }

  private func captureAnchor(in scrollView: NSScrollView) -> ResizeAnchor {
    guard let documentView = scrollView.documentView else { return .bottom }
    let visible = scrollView.contentView.documentVisibleRect
    if documentView.bounds.maxY - visible.maxY <= 24 { return .bottom }
    guard let tableView = Self.tableView(in: documentView), tableView.numberOfRows > 0 else {
      return .absoluteY(visible.minY)
    }
    let documentPoint = NSPoint(x: visible.midX, y: visible.minY + 1)
    let tablePoint = tableView.convert(documentPoint, from: documentView)
    let row = tableView.row(at: tablePoint)
    guard row >= 0 else { return .absoluteY(visible.minY) }
    let rowRect = tableView.convert(tableView.rect(ofRow: row), to: documentView)
    return .row(index: row, offset: visible.minY - rowRect.minY)
  }

  private func userWillScroll(_ event: NSEvent) {
    guard let scrollView, event.window === scrollView.window else { return }
    let location = scrollView.convert(event.locationInWindow, from: nil)
    guard scrollView.bounds.contains(location) else { return }
    // 滚轮事件路径必须严格 O(1)。最终宽度帧通常已经在 mouseUp 后的主队列
    // 周期完成；即使它仍待执行，也直接放弃该帧，绝不在首个滚轮事件前排版。
    prioritizeUserScroll()
  }

  /// 同一个滚轮事件继续交给 NSScrollView；这里只取消旧锚点与事件监听，
  /// 不触发任何同步布局。
  func prioritizeUserScroll() {
    cancelResizeAnchoringForUserScroll()
    removeScrollWheelMonitor()
  }

  /// 必须保持 O(1)：在滚轮事件分发前调用，不能触发布局或滚动写入。
  private func cancelResizeAnchoringForUserScroll() {
    guard resizeAnchor != nil else { return }
    // 输入事件绝不能触发布局。上一版在这里同步失效全部行高，长会话会让
    // mouseUp 后的第一下滚轮等待近 1 秒。用户开始滚动即放弃 resize 锚定，
    // 让同一个滚轮事件直接交给 NSScrollView。
    resizeGeneration += 1
    layoutScheduled = false
    finishAfterLayout = false
    resizeAnchor = nil
  }

  private func refreshHeightMap(preserving anchor: ResizeAnchor?) {
    guard let scrollView, let tableView = Self.tableView(in: scrollView.documentView) else { return }
    let changedRows = delegateProxy.prepareHeights(for: tableView.bounds.width)
    let validRows = changedRows.intersection(IndexSet(integersIn: 0..<tableView.numberOfRows))
    if !validRows.isEmpty {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        tableView.noteHeightOfRows(withIndexesChanged: validRows)
        tableView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
      }
    }
    if let anchor { apply(anchor, in: scrollView) }
  }

  private func ensureHeightDelegateInstalled() {
    guard let scrollView, let tableView = Self.tableView(in: scrollView.documentView) else { return }
    delegateProxy.install(on: tableView)
  }

  private func restoreOriginalTableDelegate() {
    delegateProxy.restore()
  }

  private static func tableView(in view: NSView?) -> NSTableView? {
    guard let view else { return nil }
    if let tableView = view as? NSTableView { return tableView }
    for child in view.subviews {
      if let tableView = tableView(in: child) { return tableView }
    }
    return nil
  }

  private func removeScrollWheelMonitor() {
    guard let scrollWheelMonitor else { return }
    NSEvent.removeMonitor(scrollWheelMonitor)
    self.scrollWheelMonitor = nil
  }

}

/// 仅覆写可变行高查询，其它 SwiftUI 私有 delegate 消息全部转发回原对象。
/// `noteHeightOfRows` 因此只读取同步数值，不触发自动行高动画或离屏 cell 布局。
@MainActor
private final class AITranscriptTableDelegateProxy: NSObject, NSTableViewDelegate, NSOutlineViewDelegate {
  weak var tableView: NSTableView?
  weak var originalDelegate: (any NSTableViewDelegate)?
  private var originalUsesAutomaticRowHeights = true
  private var originalRowSizeStyle: NSTableView.RowSizeStyle = .default
  private var messages: [AIChatStore.ChatMessage] = []
  private weak var changeStore: AIChangeStore?
  private var preparedHeights: [CGFloat] = []
  private var preparedWidth: CGFloat = -1
  private var contentChanged = true

  func update(messages: [AIChatStore.ChatMessage], changeStore: AIChangeStore?) {
    self.messages = messages
    self.changeStore = changeStore
    contentChanged = true
  }

  func prepareHeights(for width: CGFloat) -> IndexSet {
    let width = max(width, 40)
    guard contentChanged || abs(width - preparedWidth) > 0.01 || preparedHeights.count != messages.count else { return [] }
    let previous = preparedHeights
    preparedWidth = width
    contentChanged = false
    guard let changeStore else {
      preparedHeights = Array(repeating: 1, count: messages.count)
      return changedIndexes(previous: previous, next: preparedHeights)
    }
    preparedHeights = messages.map {
      AIChatMessageRow.estimatedHeight(for: $0, tableWidth: width, changeStore: changeStore)
    }
    return changedIndexes(previous: previous, next: preparedHeights)
  }

  private func changedIndexes(previous: [CGFloat], next: [CGFloat]) -> IndexSet {
    let sharedCount = min(previous.count, next.count)
    var changed = IndexSet((0..<sharedCount).filter { abs(next[$0] - previous[$0]) > 0.5 })
    if next.count > sharedCount {
      changed.formUnion(IndexSet(integersIn: sharedCount..<next.count))
    }
    return changed
  }

  func install(on tableView: NSTableView) {
    if self.tableView !== tableView {
      restore()
      self.tableView = tableView
      originalUsesAutomaticRowHeights = tableView.usesAutomaticRowHeights
      originalRowSizeStyle = tableView.rowSizeStyle
    }
    if (tableView.delegate as AnyObject?) !== self {
      originalDelegate = tableView.delegate
      tableView.delegate = self
    }
    tableView.usesAutomaticRowHeights = false
    tableView.rowSizeStyle = .custom
  }

  func restore() {
    guard let tableView else { return }
    if (tableView.delegate as AnyObject?) === self {
      tableView.delegate = originalDelegate
    }
    tableView.usesAutomaticRowHeights = originalUsesAutomaticRowHeights
    tableView.rowSizeStyle = originalRowSizeStyle
    self.tableView = nil
    originalDelegate = nil
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    estimatedHeight(forRow: row)
  }

  /// SwiftUI 的 macOS `List` 实际使用 `SwiftUIOutlineListView`。NSOutlineView
  /// 不查询 NSTableView 的 `heightOfRow`，而是查询这个逐 item 接口。
  func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    estimatedHeight(forRow: outlineView.row(forItem: item))
  }

  private func estimatedHeight(forRow row: Int) -> CGFloat {
    guard preparedHeights.indices.contains(row) else {
      return 1
    }
    return preparedHeights[row]
  }

  override func responds(to selector: Selector!) -> Bool {
    if selector == #selector(NSTableViewDelegate.tableView(_:heightOfRow:)) { return true }
    if selector == #selector(NSOutlineViewDelegate.outlineView(_:heightOfRowByItem:)) { return true }
    if super.responds(to: selector) { return true }
    return (originalDelegate as? NSObjectProtocol)?.responds(to: selector) == true
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if (originalDelegate as? NSObjectProtocol)?.responds(to: selector) == true {
      return originalDelegate
    }
    return super.forwardingTarget(for: selector)
  }
}

/// SwiftUI List 不公开其 NSScrollView。透明背景视图按窗口坐标匹配与自身
/// 重叠面积最大的滚动容器，从而把右侧 AI transcript 精确交给协调器。
private struct AITranscriptScrollResolver: NSViewRepresentable {
  let coordinator: AITranscriptScrollCoordinator
  let messages: [AIChatStore.ChatMessage]
  let changeStore: AIChangeStore

  func makeNSView(context: Context) -> AITranscriptScrollResolverView {
    let view = AITranscriptScrollResolverView()
    view.coordinator = coordinator
    coordinator.updateContent(messages: messages, changeStore: changeStore)
    view.resolveLater()
    return view
  }

  func updateNSView(_ nsView: AITranscriptScrollResolverView, context: Context) {
    nsView.coordinator = coordinator
    coordinator.updateContent(messages: messages, changeStore: changeStore)
    nsView.resolveLater()
  }
}

private final class AITranscriptScrollResolverView: NSView {
  weak var coordinator: AITranscriptScrollCoordinator?
  private var resolveScheduled = false

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    resolveLater()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil, coordinator?.scrollView === resolvedScrollView {
      coordinator?.attach(nil)
    }
    super.viewWillMove(toWindow: newWindow)
  }

  private weak var resolvedScrollView: NSScrollView?

  func resolveLater() {
    guard !resolveScheduled else { return }
    resolveScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.resolveScheduled = false
      self.resolve()
    }
  }

  private func resolve() {
    guard bounds.width > 0, bounds.height > 0, let root = window?.contentView else { return }
    let markerFrame = convert(bounds, to: nil)
    let candidates = Self.scrollViews(in: root).compactMap { scrollView -> (NSScrollView, CGFloat)? in
      let frame = scrollView.convert(scrollView.bounds, to: nil)
      let overlap = markerFrame.intersection(frame)
      guard !overlap.isNull, overlap.width > 80, overlap.height > 120 else { return nil }
      return (scrollView, overlap.width * overlap.height)
    }
    guard let best = candidates.max(by: { $0.1 < $1.1 })?.0 else { return }
    resolvedScrollView = best
    coordinator?.attach(best)
  }

  private static func scrollViews(in view: NSView) -> [NSScrollView] {
    var result: [NSScrollView] = []
    if let scrollView = view as? NSScrollView { result.append(scrollView) }
    for child in view.subviews {
      result.append(contentsOf: scrollViews(in: child))
    }
    return result
  }
}

/// 侧边栏 AI 助手（FR-AI.2）：替代式单栏面板——与右侧上下文面板同位切换。
/// 多轮流式对话（可取消/重试）+ 两层上下文 chips + 回复五动作。
struct AIAssistantPanelView: View {
  @EnvironmentObject private var chat: AIChatStore
  @EnvironmentObject private var aiSettings: AISettingsStore
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var workspaceStore: WorkspaceStore
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @EnvironmentObject private var transcriptScroll: AITranscriptScrollCoordinator

  @State private var draft = ""
  @State private var toast: String?
  @FocusState private var inputFocused: Bool
  /// 回车发送 / ⌘↵ 换行监听（TextEditor 内 onKeyPress 拿不到修饰键，走 AppKit 通道）
  @State private var sendKeyMonitor: Any?
  /// 视口是否贴着底部（流式自动滚动仅贴底时生效）
  @State private var isPinnedToBottom = true

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      // 上下两栏走系统 NSSplitView：分隔条原生连续拖动（同左右边栏手感），
      // 此前 DragGesture 逐帧写 @State 导致整棵 body 重算（抽搐根因）
      ComposerSplitView(
        top: {
          VStack(spacing: 0) {
            if chat.messages.isEmpty, chat.phase == .idle {
              emptyState
            } else {
              messageList
            }
            if case .failed(let message) = chat.phase {
              failureRow(message)
            }
            if let toast {
              Text(toast)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
            }
          }
        },
        bottom: {
          // 分栏撑高时内容顶部对齐（默认会居中悬浮）
          composer.frame(maxHeight: .infinity, alignment: .top)
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.background)
    .onAppear {
      // 交互约定（2026-08-19 用户决策）：回车发送；⌘↵ 在光标处换行（TextEditor
      // 默认不响应 cmd+return，须手动向响应者插入）
      sendKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
        guard event.keyCode == 36, inputFocused else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
          if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.insertText("\n")
            return nil
          }
          return event
        }
        sendDraft()
        return nil
      }
    }
    .onDisappear {
      if let sendKeyMonitor {
        NSEvent.removeMonitor(sendKeyMonitor)
      }
    }
  }

  // MARK: - 头部

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles")
          .foregroundStyle(.secondary)
        Text("AI 助手")
          .font(.system(size: AppTypography.panelTitle, weight: .semibold))
        if !chat.providerBadge.isEmpty {
          Text(chat.providerBadge)
            .font(.system(size: AppTypography.secondary))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Spacer()
        // AI 写作开关（2026-08-19）：带文字胶囊，状态与作用一眼可辨
        Button {
          chat.isWritingMode.toggle()
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "pencil.line")
              .font(.system(size: AppTypography.metadata, weight: .semibold))
            Text("写作")
              .font(.system(size: AppTypography.secondary, weight: .medium))
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            chat.isWritingMode ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
            in: Capsule()
          )
          .foregroundStyle(chat.isWritingMode ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(chat.isWritingMode ? "AI 写作已开：提问将产出文件变更提案（点击关闭）" : "AI 写作已关：仅问答（点击开启写作）")
        Button {
          chat.newSession()
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("清空当前会话，重新开始")
        .disabled(chat.messages.isEmpty)
        Button {
          workspaceStore.isAIAssistantPresented = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help("关闭 AI 助手")
      }
      // 会话线程归属（FR-AI.3：每文档一条线程，切文档自动切换）
      Text(threadCaption)
        .font(.system(size: AppTypography.secondary))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .alert(
      "AI 会话文件损坏",
      isPresented: Binding(
        get: { chat.storageError != nil },
        set: { if !$0 { chat.storageError = nil } }
      )
    ) {
      Button("好") { chat.storageError = nil }
    } message: {
      Text(chat.storageError ?? "")
    }
  }

  private var threadCaption: String {
    // 工作区内外会话均持久（外部打开写全局存储，线程跟文件走）
    chat.activeDocName.map { String(localized: "会话：\($0)") } ?? String(localized: "会话：工作区通用")
  }

  // MARK: - 消息列表

  /// 贴底锚点的滚动目标 id（锚自身成为目标，滚到底它必可见——
  /// 目标为最后一条消息时，1pt 锚悬在可见边界反复触发贴底/松手，即「到底抽搐」根因）
  private let bottomAnchorID = "ai-chat-bottom-anchor"

  private var messageList: some View {
    ScrollViewReader { proxy in
      // macOS List 由 NSTableView 按消息行虚拟化并维护可见行锚点。
      // 与 LazyVStack 不同，历史行高度因换行改变时不会用估算总高反复修正
      // contentOffset；同时拖宽只排版可见消息，不再每帧测量整个会话。
      List {
        ForEach(chat.messages) { message in
          AIChatMessageRow(
            message: message,
            isBusy: chat.phase == .streaming,
            changeStore: chat.changeStore
          )
          .id(message.id)
          .listRowInsets(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        }

        Color.clear
          .frame(height: 1)
          .id(bottomAnchorID)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 1)
      .background(AITranscriptScrollResolver(
        coordinator: transcriptScroll,
        messages: chat.messages,
        changeStore: chat.changeStore
      ))
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.visibleRect.maxY >= geometry.contentSize.height - 24
      } action: { _, pinned in
        isPinnedToBottom = pinned
      }
      // 仅在内容变化且贴底时自动滚（用户拖条/上翻期间不做任何程序化滚动）；
      // 目标是锚点自身（回到底部后锚点可见，贴底状态自然恢复）
      .onChange(of: chat.messages.last?.content) { _, _ in
        guard isPinnedToBottom else { return }
        proxy.scrollTo(bottomAnchorID)
      }
      // 首次出现与切换文档线程（activeDocName 变化 = 换了会话）时回到最新消息：
      // 历史消息列表重建后 ScrollView 停在顶部，需主动滚底
      .onAppear {
        isPinnedToBottom = true
        DispatchQueue.main.async {
          proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
      }
      .onChange(of: chat.activeDocName) { _, _ in
        isPinnedToBottom = true
        DispatchQueue.main.async {
          proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "sparkles")
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
      if chat.providerBadge.isEmpty {
        Text("先在 设置 → AI 启用并配置一个 Provider")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("打开设置") {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        .controlSize(.small)
      } else {
        Text("向 AI 提问当前文档或选中内容")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding()
  }

  private func failureRow(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(message)
        .font(.system(size: AppTypography.secondary))
        .foregroundStyle(.red)
        .lineLimit(3)
      Spacer()
      Button("重试") { chat.retry() }
        .controlSize(.small)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  // MARK: - 输入区

  private var composer: some View {
    VStack(alignment: .leading, spacing: 6) {
      contextChips
      HStack(alignment: .bottom, spacing: 8) {
        // TextEditor：长文超出自动内滚（TextField 长文不滚动的实测反馈）；
        // 回车发送、⌘↵ 换行（2026-08-19 用户决策）
        ZStack(alignment: .topLeading) {
          TextEditor(text: $draft)
            .font(.system(size: AppTypography.primary))
            .scrollContentBackground(.hidden)
            // 高度交给外层分栏的下栏（ NSSplitView 逐帧驱动）
            .frame(minHeight: 56, maxHeight: .infinity)
            .focused($inputFocused)
          if draft.isEmpty {
            Text(chat.isWritingMode ? "描述要写或要改的文件…（回车发送，⌘↵ 换行）" : "向 AI 提问…（回车发送，⌘↵ 换行）")
              .font(.system(size: AppTypography.primary))
              .foregroundStyle(.tertiary)
              // 实测对齐（textprobe）：TextEditor 内部 textContainerInset=(0,0)、
              // lineFragmentPadding=5，空文本光标行顶格 y=0 高 17pt——
              // 占位符同为 17pt 行，仅补 leading 5 即与光标同行同列
              .padding(.leading, 5)
              .allowsHitTesting(false)
          }
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        if chat.phase == .streaming {
          Button {
            chat.cancel()
          } label: {
            Image(systemName: "stop.circle.fill")
              .font(.system(size: 18))
              .foregroundStyle(.red)
          }
          .buttonStyle(.plain)
          .help("停止生成")
        } else {
          Button(action: sendDraft) {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 18))
              .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
          }
          .buttonStyle(.plain)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .help("发送")
        }
      }
    }
    .padding(10)
  }

  /// 上下文 chips：直写设置（单一事实源，与 设置 → AI 同步）
  private var contextChips: some View {
    HStack(spacing: 6) {
      contextChip(
        title: String(localized: "选中文字"),
        isOn: aiSettings.settings.contextIncludeSelection
      ) { aiSettings.update { $0.contextIncludeSelection.toggle() } }
      contextChip(
        title: String(localized: "当前文档"),
        isOn: aiSettings.settings.contextIncludeDocument
      ) { aiSettings.update { $0.contextIncludeDocument.toggle() } }
      contextChip(
        title: String(localized: "工作区"),
        isOn: aiSettings.settings.contextIncludeWorkspace
      ) { aiSettings.update { $0.contextIncludeWorkspace.toggle() } }
      Spacer()
    }
  }

  private func contextChip(title: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
    Button(action: toggle) {
      HStack(spacing: 4) {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .font(.system(size: AppTypography.metadata))
        Text(title)
          .font(.system(size: AppTypography.secondary))
          .lineLimit(1)
      }
      .fixedSize()
      .foregroundStyle(isOn ? Color.accentColor : .secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        (isOn ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)),
        in: Capsule()
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(String(localized: "该轮提问是否附带此上下文（与 设置 → AI 同步）"))
  }

  private func sendDraft() {
    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, chat.phase != .streaming else { return }
    draft = ""
    // 自己发问视为回到追更状态（滚动恢复自动跟随）
    isPinnedToBottom = true
    chat.send(question)
  }

}

/// 输入区上下分栏容器：系统 NSSplitView 原生分隔条（与左右边栏同一套连续拖动）。
/// DragGesture 逐帧写 @State 会整棵重算消息列表（拖动抽搐根因）；
/// NSSplitView 原生跟踪只改几何不进 SwiftUI 状态
private enum ComposerSplitMetrics {
  /// 下栏（输入区整体）高度限值：输入框 56–400 + chips 行与内外边距约 64
  static let minBottom: CGFloat = 120
  static let maxBottom: CGFloat = 470
  /// 首次布局的默认下栏高度（≈ 自动模式的观感）
  static let defaultBottom: CGFloat = 150
}

private struct ComposerSplitView<Top: View, Bottom: View>: NSViewRepresentable {
  @ViewBuilder let top: () -> Top
  @ViewBuilder let bottom: () -> Bottom

  func makeNSView(context: Context) -> NSSplitView {
    let split = ComposerSplitNSSplitView()
    split.isVertical = false
    split.dividerStyle = .thin
    let topHost = NSHostingView(rootView: top())
    let bottomHost = NSHostingView(rootView: bottom())
    // sizingOptions=[]（macOS 13+）：hosting 不再向外报 SwiftUI 内容的固有尺寸，
    // 否则消息列表的内容高度变成硬约束，上栏缩不动，拖动时与分栏布局打架
    //（输入框变不大/面板被顶歪/松手回位的根因）
    topHost.sizingOptions = []
    bottomHost.sizingOptions = []
    split.addArrangedSubview(topHost)
    split.addArrangedSubview(bottomHost)
    // holdingPriority 保持两栏相等（默认 250）：若下栏更高（曾设 260），
    // 拖动分隔条时 NSSplitView 会保下栏高度而直接改自身外框尺寸
    //（实测日志：外框随分隔条位移逐帧等量塌缩 → 整体移动、松手回位）
    split.delegate = context.coordinator
    return split
  }

  func updateNSView(_ split: NSSplitView, context: Context) {
    guard split.arrangedSubviews.count == 2,
      let topHost = split.arrangedSubviews[0] as? NSHostingView<Top>,
      let bottomHost = split.arrangedSubviews[1] as? NSHostingView<Bottom>
    else { return }
    topHost.rootView = top()
    bottomHost.rootView = bottom()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, NSSplitViewDelegate {
    func splitView(
      _ splitView: NSSplitView,
      constrainSplitPosition proposedPosition: CGFloat,
      ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
      let total = splitView.bounds.height - splitView.dividerThickness
      guard total > 0 else { return proposedPosition }
      let lowerBound = min(ComposerSplitMetrics.minBottom, total * 0.7)
      let bottom = min(max(total - proposedPosition, lowerBound), ComposerSplitMetrics.maxBottom)
      return total - bottom
    }
  }
}

/// 首次布局时把分隔条落到默认输入区高度（NSSplitView 默认均分，会各占一半）
final class ComposerSplitNSSplitView: NSSplitView {
  private var didInitialLayout = false

  // 防御：分栏拖动/窗口变化会失效 intrinsic 尺寸，SwiftUI 可能据此重议外框。
  // 对外不报告固有尺寸且不再发失效通知，外框完全由 SwiftUI 布局决定
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func invalidateIntrinsicContentSize() {}

  override func layout() {
    super.layout()
    guard !didInitialLayout, bounds.height > 80 else { return }
    didInitialLayout = true
    let total = bounds.height - dividerThickness
    let bottom = min(max(ComposerSplitMetrics.defaultBottom, ComposerSplitMetrics.minBottom), total * 0.75)
    setPosition(total - bottom, ofDividerAt: 0)
  }
}

#Preview {
  AIAssistantPanelView()
    .environmentObject(AIChatStore(
      settings: AISettingsStore(),
      service: AIService(keys: AIKeyStore())
    ))
    .environmentObject(AISettingsStore())
    .environmentObject(TabStore())
    .environmentObject(WorkspaceStore())
    .environmentObject(PDFReaderStore())
    .environmentObject(AITranscriptScrollCoordinator())
    .frame(width: 320, height: 560)
}
