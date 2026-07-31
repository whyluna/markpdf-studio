import AppKit
import PDFKit
import SwiftUI

/// 单窗口的状态容器（v1.5 多窗口）：每个窗口一套独立的工作区/标签/阅读/AI 状态，
/// 跨 store 接线（原 ContentView.onAppear 闭包总线）收口在 wireUp。
/// 共享层（设置/密钥/快照存储/最近打开等）由 App 注入，跨窗口单实例
@MainActor
final class WindowSession: ObservableObject, Identifiable {
  let id = UUID()
  let workspaceStore = WorkspaceStore()
  let tabStore = TabStore()
  let pdfStore = PDFReaderStore()
  let pdfBookmarksStore = PDFBookmarksStore()
  let imageStore = ImagePreviewStore()
  let annotationStore = PDFAnnotationStore()
  let searchStore = SearchStore()
  let backlinksStore = BacklinksStore()
  let stateStore: WorkspaceStateStore
  let aiChatStore: AIChatStore
  /// 本窗口的 NSWindow（WindowAccessor 解析后回填；聚焦/列宽调整/关窗 flush 用）
  weak var window: NSWindow?
  /// 窗口路由中枢（打开工作区/外部文件时决定聚焦还是开新窗）
  weak var coordinator: WindowCoordinator?

  private var isWired = false

  init(
    snapshotStore: WorkspaceSnapshotStore,
    aiSettings: AISettingsStore,
    aiKeys: AIKeyStore,
    aiSessions: AISessionRepository
  ) {
    stateStore = WorkspaceStateStore(snapshotStore: snapshotStore)
    aiChatStore = AIChatStore(
      settings: aiSettings,
      service: AIService(keys: aiKeys),
      repository: aiSessions
    )
  }

  /// 本窗口全部现场立即落盘（关窗/退出前）
  func flush() {
    tabStore.flushAll()
    annotationStore.flushPendingWrites()
    stateStore.flush()
    aiChatStore.flush()
  }

  // MARK: - 窗口任务

  /// 就地打开工作区（空窗口或新窗口领到 .workspace 任务时）
  func openWorkspaceInPlace(_ folder: URL) {
    stateStore.switchWorkspace(to: folder, workspaceStore: workspaceStore, tabStore: tabStore)
  }

  /// 执行新窗口的初始任务（工作区 / 单文件 / 工作区+文件）
  func apply(_ request: WindowCoordinator.WindowRequest) {
    switch request {
    case .workspace(let folder):
      openWorkspaceInPlace(folder)
    case .file(let file):
      tabStore.open(url: file)
    case .workspaceWithFile(let root, let file):
      openWorkspaceInPlace(root)
      tabStore.open(url: file)
    }
  }

  // MARK: - 跨 store 接线（原 ContentView.onAppear；每窗口一次）

  func wireUp(recentsStore: RecentFilesStore) {
    guard !isWired else { return }
    isWired = true

    // 重命名/移动成功（含撤销/重做链）→ 标签页路径跟随；
    // 撤销在 WorkspaceStore 内闭环、不经过视图层，需在 Store 层统一通知
    workspaceStore.onFileMoved = { [weak tabStore] oldURL, newURL in
      tabStore?.fileDidMove(from: oldURL, to: newURL)
    }
    // 打开工作区（⌘⇧O/菜单/空状态按钮统一走此钩子）：经窗口路由——
    // 目标已有窗口则聚焦，本窗尚无工作区则就地打开，否则开新窗口（本窗原样不动）
    workspaceStore.onOpenFolder = { [weak self] url in
      guard let self else { return }
      guard let coordinator = self.coordinator else {
        return self.openWorkspaceInPlace(url)
      }
      coordinator.handleOpenWorkspace(url, requesting: self)
    }
    tabStore.onOpenFile = { [weak self, weak recentsStore] url in
      guard let root = self?.workspaceStore.root?.id else { return }
      recentsStore?.record(url, forRoot: root)
    }
    tabStore.onStructureChange = { [weak self] in
      guard let self else { return }
      self.stateStore.tabsDidChange(groups: self.tabStore.groups, activeGroupID: self.tabStore.activeGroupID)
      // 文件树高亮始终跟随当前激活标签（打开新文件 / 切换标签 / 切换分栏组统一入口）
      let activeURL = self.tabStore.activeGroup.activeTab?.url
      self.workspaceStore.selection = activeURL.flatMap { self.workspaceStore.node(for: $0) }
      // AI 会话按文档隔离（FR-AI.3 v1.2）：激活标签变化即切线程（同 key 幂等）
      self.aiChatStore.bindDocument(activeURL)
      // 切节预热（v1.2 性能）：激活 PDF 后台预切并缓存，首次 AI 提问不再现场解析。
      // 后台自建 PDFDocument（不碰主线程的 pdfView.document，对象单线程归属）
      if self.tabStore.activeGroup.activeTab?.kind == .pdf, let url = activeURL,
        !DocumentSectionCache.shared.isCached(url) {
        Task.detached(priority: .utility) {
          _ = DocumentSectionCache.shared.sections(for: url) {
            PDFDocument(url: url).map { DocumentSectioner.fromPDF($0) }
          }
        }
      }
    }
    tabStore.onEditorCursorLine = { [weak self] url, line in
      self?.stateStore.recordCursor(url: url, line: line)
    }
    workspaceStore.onStateChange = { [weak self] in
      guard let self else { return }
      self.stateStore.workspaceDidChange(
        root: self.workspaceStore.root?.id,
        collapsedFolders: self.workspaceStore.collapsedFolders,
        aiAssistantVisible: self.workspaceStore.isAIAssistantPresented
      )
      // 反链解析所需根目录（纯赋值，折叠态变化时同值覆盖无副作用）；
      // 重扫已分流到 onMarkdownFilesChange，自动保存/折叠不再全量重读 md
      self.backlinksStore.setWorkspaceRoot(self.workspaceStore.root?.id)
      // AI 会话随工作区载入/落盘（同根幂等；root 为扫描完成后异步赋值，届时再触发）
      self.aiChatStore.workspaceDidChange(root: self.workspaceStore.root?.id)
    }
    // 反向链接（FR-5.4）：仅 md 文件集合实际变化（新增/删除/重命名/外部变更）后重扫，新引用 5s 内出现
    workspaceStore.onMarkdownFilesChange = { [weak self] in
      self?.backlinksStore.refresh()
    }
    // 全文搜索候选（FR-6.2）：工作区全部文件
    searchStore.filesProvider = { [weak self] in
      self?.workspaceStore.allFiles.map(\.id) ?? []
    }
    // 反向链接候选（FR-5.4）：仅 md 文件
    backlinksStore.filesProvider = { [weak self] in
      self?.workspaceStore.allFiles.filter { $0.kind == .markdown }.map(\.id) ?? []
    }
    backlinksStore.setWorkspaceRoot(workspaceStore.root?.id)
    wireAIContextSources()
  }

  /// 外部打开路由接线（v1.5①：首窗承接，保持单窗口时代行为；②改窗口感知路由）
  func wireExternalOpen(_ externalOpen: ExternalOpenCoordinator) {
    externalOpen.openFileTab = { [weak self] url in
      self?.tabStore.open(url: url)
    }
    externalOpen.currentRootPath = { [weak self] in
      self?.stateStore.currentRootPath
    }
    externalOpen.switchWorkspaceTo = { [weak self] url in
      guard let self else { return }
      self.stateStore.switchWorkspace(to: url, workspaceStore: self.workspaceStore, tabStore: self.tabStore)
    }
  }

  /// AI 助手上下文源（FR-AI.2 两层：选区 / 当前文档；工作区工具 v1.3）
  private func wireAIContextSources() {
    aiChatStore.contextSources.isPDFActive = { [weak self] in
      self?.tabStore.activeGroup.activeTab?.kind == .pdf
    }
    aiChatStore.contextSources.pdfSelection = { [weak self] in
      guard let raw = self?.pdfStore.pdfView?.currentSelection?.string else { return nil }
      let text = TranslationTextNormalizer.normalize(raw)
      return text.isEmpty ? nil : text
    }
    aiChatStore.contextSources.mdSelection = { [weak self] completion in
      guard let store = self?.tabStore.activeEditorStore else { return completion(nil) }
      store.fetchSelection { text in
        completion((text?.isEmpty ?? true) ? nil : text)
      }
    }
    aiChatStore.contextSources.activeDocument = { [weak self] budget in
      guard let self, let tab = self.tabStore.activeGroup.activeTab else { return nil }
      switch tab.kind {
      case .markdown:
        guard let store = self.tabStore.activeEditorStore else { return nil }
        return (name: tab.title, text: store.text)
      case .pdf:
        guard let document = self.pdfStore.pdfView?.document else { return nil }
        // 逐页拼接、到预算即停（大 PDF 全量 string 提取可达百 ms 级；
        // 预算随所选模型窗口动态传入，v1.2）
        var text = ""
        for index in 0..<document.pageCount {
          guard text.count < budget else { break }
          if let page = document.page(at: index)?.string {
            text += page + "\n"
          }
        }
        return text.isEmpty ? nil : (name: tab.title, text: text)
      default:
        return nil
      }
    }
    // 结构切节（超预算两遍路由用，v1.2）：md 标题树 / PDF 书签（无书签每页一节）。
    // md 用编辑器实时文本（未落盘也准，切节快不缓存）；PDF 走缓存（预热后免主线程解析）
    aiChatStore.contextSources.documentSections = { [weak self] in
      guard let self, let tab = self.tabStore.activeGroup.activeTab else { return nil }
      switch tab.kind {
      case .markdown:
        guard let store = self.tabStore.activeEditorStore else { return nil }
        return DocumentSectioner.fromMarkdown(store.text)
      case .pdf:
        guard let url = tab.url else { return nil }
        return DocumentSectionCache.shared.sections(for: url) {
          self.pdfStore.pdfView?.document.map { DocumentSectioner.fromPDF($0) }
        }
      default:
        return nil
      }
    }
    // 工作区工具（v1.3 agent 循环）：根 + 文件清单供工具执行与 system 提示
    aiChatStore.contextSources.workspaceFiles = { [weak self] in
      let files = self?.workspaceStore.allFiles
        .filter { $0.kind == .markdown || $0.kind == .pdf }
        .map(\.id) ?? []
      return (root: self?.workspaceStore.root?.id, files: files)
    }
  }
}
