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
      Divider()
      composerDragDivider
      composer
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

  /// 输入区手动高度（nil = 自动 56–120pt 自适应；拖动分界线后进入手动）
  @State private var composerHeight: CGFloat?
  /// 拖动中的幽灵线偏移（仅预览不触发布局——逐帧重排消息列表是抖动根因）
  @State private var composerDragOffset: CGFloat = 0
  /// 输入区实测高度（自动模式下的拖动起点）
  @State private var measuredComposerHeight: CGFloat = 88

  // MARK: - 输入区

  /// 输入区高度拖拽分界线（悬停变上下箭头；拖动只显幽灵线，松手一次性应用，56–400pt）
  private var composerDragDivider: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.2))
      .frame(height: 1)
      .padding(.vertical, 4)  // 命中带 ~9pt，视觉仍是细线
      .contentShape(Rectangle())
      .overlay {
        if composerDragOffset != 0 {
          // 幽灵线：新分界位置预览（不触发任何重排）
          Rectangle()
            .fill(Color.accentColor.opacity(0.5))
            .frame(height: 2)
            .offset(y: composerDragOffset)
        }
      }
      .onHover { hovering in
        if hovering {
          NSCursor.resizeUpDown.push()
        } else {
          NSCursor.pop()
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            composerDragOffset = value.translation.height
          }
          .onEnded { value in
            let startHeight = composerHeight ?? measuredComposerHeight
            composerHeight = min(max(startHeight - value.translation.height, 56), 400)
            composerDragOffset = 0
          }
      )
      .help("拖拽调整输入区高度")
  }

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
            .frame(
              minHeight: composerHeight ?? 56,
              maxHeight: composerHeight ?? 120
            )
            .focused($inputFocused)
            .background(
              GeometryReader { geometry in
                Color.clear.onAppear {
                  measuredComposerHeight = geometry.size.height
                }
              }
            )
          if draft.isEmpty {
            Text("向 AI 提问…（⌘↵ 发送）")
              .font(.system(size: 14))
              .foregroundStyle(.tertiary)
              // TextEditor 文本起点 = 容器 6 + 内建 inset 5，占位符同构对齐
              .padding(.horizontal, 5)
              .padding(.vertical, 6)
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
      }
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
      tabStore?.activeEditorStore?.enqueue(.replaceSelection(text) { replaced in
        if !replaced { showToast(String(localized: "编辑器中没有选中内容")) }
      })
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
