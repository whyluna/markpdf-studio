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
      composer
    }
    .background(.background)
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
            .font(.caption2)
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
        .font(.caption2)
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
    let owner = chat.activeDocName.map { String(localized: "会话：\($0)") } ?? String(localized: "会话：工作区通用")
    return chat.isPersistent ? owner : owner + String(localized: "（无工作区，重启不保留）")
  }

  // MARK: - 消息列表

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(chat.messages) { message in
            AIChatMessageRow(
              message: message,
              isBusy: chat.phase == .streaming,
              actions: messageActions
            )
            .id(message.id)
          }
        }
        .padding(10)
      }
      // 流式增量与新消息都滚到底（节流批量落地，频率可控）
      .onChange(of: chat.messages.last?.content) { _, _ in
        if let last = chat.messages.last?.id {
          proxy.scrollTo(last, anchor: .bottom)
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
        TextField("向 AI 提问…", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.body)
          .lineLimit(3...10)
          .padding(8)
          .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
          .focused($inputFocused)
          .onSubmit(sendDraft)
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
      Spacer()
    }
  }

  private func contextChip(title: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
    Button(action: toggle) {
      HStack(spacing: 3) {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 9))
        Text(title)
          .font(.caption2)
      }
      .foregroundStyle(isOn ? Color.accentColor : .secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
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
