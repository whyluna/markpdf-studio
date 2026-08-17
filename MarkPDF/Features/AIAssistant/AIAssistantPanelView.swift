import SwiftUI

/// 侧边栏 AI 助手（FR-AI.2）：替代式单栏面板——与右侧上下文面板同位切换。
/// 多轮流式对话（可取消/重试）+ 两层上下文 chips + 回复五动作。
struct AIAssistantPanelView: View {
  @EnvironmentObject private var chat: AIChatStore
  @EnvironmentObject private var aiSettings: AISettingsStore
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var workspaceStore: WorkspaceStore
  @EnvironmentObject private var pdfStore: PDFReaderStore

  @State private var draft = ""
  @State private var toast: String?
  @FocusState private var inputFocused: Bool
  /// ⌘↵ 发送监听（TextEditor 内 onKeyPress 拿不到修饰键，走 AppKit 通道）
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
      sendKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
        if event.keyCode == 36,
          event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
          inputFocused
        {
          sendDraft()
          return nil
        }
        return event
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
          .font(.headline)
        if !chat.providerBadge.isEmpty {
          Text(chat.providerBadge)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          chat.newSession()
        } label: {
          Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.plain)
        .help("新会话")
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
        .font(.caption)
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
      ScrollView {
        Group {
          // 中小规模对话全量布局：内容高度首帧即精确（滚动条永远成比例——
          // LazyVStack 靠近底部才物化高公式行，总长突然撑大致滚动条跳变，实测反馈）
          if chat.messages.count <= Self.eagerMessageLimit {
            VStack(alignment: .leading, spacing: 14) {
              messageRows
            }
          } else {
            LazyVStack(alignment: .leading, spacing: 14) {
              messageRows
            }
          }
        }
        .padding(10)
      }
      // 仅在内容变化且贴底时自动滚（用户拖条/上翻期间不做任何程序化滚动）；
      // 目标是锚点自身（回到底部后锚点可见，贴底状态自然恢复）
      .onChange(of: chat.messages.last?.content) { _, _ in
        guard isPinnedToBottom else { return }
        proxy.scrollTo(bottomAnchorID)
      }
    }
  }

  /// 全量布局的消息数上限（内滚行总数 ≈ 条数 × 平均块数，控制在数百视图内）
  private static let eagerMessageLimit = 30

  @ViewBuilder
  private var messageRows: some View {
    ForEach(chat.messages) { message in
      AIChatMessageRow(
        message: message,
        isBusy: chat.phase == .streaming,
        actions: messageActions
      )
      .id(message.id)
    }
    // 贴底锚点：可见才算贴底——用户上翻即松手
    Color.clear
      .frame(height: 1)
      .id(bottomAnchorID)
      .onAppear { isPinnedToBottom = true }
      .onDisappear { isPinnedToBottom = false }
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
        .font(.caption)
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
        // ⌘↵ 发送、回车换行（长输入场景更合理）
        ZStack(alignment: .topLeading) {
          TextEditor(text: $draft)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            // 高度交给外层分栏的下栏（ NSSplitView 逐帧驱动）
            .frame(minHeight: 56, maxHeight: .infinity)
            .focused($inputFocused)
          if draft.isEmpty {
            Text("向 AI 提问…（⌘↵ 发送）")
              .font(.system(size: 14))
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
          .font(.system(size: 11))
        Text(title)
          .font(.callout)
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

  // MARK: - 五动作接线（FR-AI.2）

  private var messageActions: AIMessageActions {
    var actions = AIMessageActions()
    actions.canInsert = { [weak tabStore] in
      guard let store = tabStore?.activeEditorStore else { return false }
      return store.mode != .reading  // 阅读模式内核只读
    }
    actions.insertAtCursor = { [weak tabStore] text in
      tabStore?.activeEditorStore?.enqueue(.insertAtCursor(text))
    }
    actions.replaceSelection = { [weak tabStore] text in
      tabStore?.activeEditorStore?.replaceSelection(text) { replaced in
        if !replaced { showToast(String(localized: "编辑器中没有选中内容")) }
      }
    }
    actions.canSaveNote = { [weak workspaceStore] in workspaceStore?.root != nil }
    actions.saveAsNote = { [weak workspaceStore, weak tabStore] text in
      guard let root = workspaceStore?.root?.id else { return }
      if let url = workspaceStore?.createMarkdown(
        in: root, content: text, baseName: String(localized: "AI 笔记"), undo: nil
      ) {
        tabStore?.open(url: url)
      }
    }
    actions.canQuote = { [weak tabStore] in
      tabStore?.activeGroup.activeTab?.kind == .pdf && tabStore?.activeGroup.activeTab?.url != nil
    }
    actions.copyAsQuote = { [weak tabStore, weak workspaceStore, weak pdfStore] text in
      guard let pdfURL = tabStore?.activeGroup.activeTab?.url else { return }
      let quote = PDFQuoteExporter.quoteText(
        text: text,
        pdfURL: pdfURL,
        page: pdfStore?.currentPage ?? 1,
        workspaceRoot: workspaceStore?.root?.id
      )
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(quote, forType: .string)
      showToast(String(localized: "已复制带回链的引用"))
    }
    return actions
  }

  private func showToast(_ message: String) {
    toast = message
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      if toast == message { toast = nil }
    }
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
    .frame(width: 320, height: 560)
}
