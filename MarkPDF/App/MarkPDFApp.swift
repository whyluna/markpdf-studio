import SwiftUI
import os

@main
struct MarkPDFApp: App {
  @StateObject private var workspaceStore = WorkspaceStore()
  @StateObject private var tabStore: TabStore
  @StateObject private var pdfStore = PDFReaderStore()
  @StateObject private var pdfBookmarksStore = PDFBookmarksStore()
  @StateObject private var imageStore = ImagePreviewStore()
  @StateObject private var annotationStore: PDFAnnotationStore
  @StateObject private var readingPositionStore = PDFReadingPositionStore()
  @StateObject private var favoritesStore = FavoritesStore()
  @StateObject private var recentsStore = RecentFilesStore()
  @StateObject private var stateStore: WorkspaceStateStore
  @StateObject private var settingsStore = SettingsStore()
  @StateObject private var searchStore = SearchStore()
  @StateObject private var backlinksStore = BacklinksStore()
  // AI（FR-AI.4）：偏好与密钥均为 App 级单例（设置页 / 划词翻译 / AI 助手共用）
  @StateObject private var aiSettingsStore = AISettingsStore()
  @StateObject private var aiKeyStore = AIKeyStore()
  // Finder 直接打开文件的路由（文档类型见 Info.plist CFBundleDocumentTypes）
  @StateObject private var externalOpen = ExternalOpenCoordinator()
  // 默认打开方式开关（设置 → 通用）
  @StateObject private var defaultHandlerService = DefaultHandlerService()

  init() {
    let tabStore = TabStore()
    let annotationStore = PDFAnnotationStore()
    let stateStore = WorkspaceStateStore()
    _tabStore = StateObject(wrappedValue: tabStore)
    _annotationStore = StateObject(wrappedValue: annotationStore)
    _stateStore = StateObject(wrappedValue: stateStore)
    // 退出前兜底落盘（FR-2.7 全部标签 + FR-4.6 标注写回 + FR-1.6 快照）挂在 App 级：
    // 红钮关窗后再 ⌘Q 时 ContentView 已销毁、无人接收通知，防抖窗口内的保存/快照会丢。
    // 三个 store 均为 App 级单例，观察者随进程生命周期存续，无循环引用
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { _ in
      tabStore.flushAll()
      annotationStore.flushPendingWrites()
      stateStore.flush()
    }
  }

  /// 当前标签是否可缩放（PDF / 图片）
  private var zoomable: Bool {
    let kind = tabStore.activeGroup.activeTab?.kind
    return kind == .pdf || kind == .image
  }

  /// 缩放命令路由：PDF → pdfStore，图片 → imageStore
  private func zoomAction(_ action: (ZoomTarget) -> Void) {
    switch tabStore.activeGroup.activeTab?.kind {
    case .pdf: action(pdfStore)
    case .image: action(imageStore)
    default: break
    }
  }

  /// 复制为带回链的引用块（FR-5.2）：委托 PDFQuoteExporter（与命令面板共用）
  private func copyPDFSelectionAsQuote() {
    PDFQuoteExporter.copyAsQuote(
      pdfView: pdfStore.pdfView,
      currentPage: pdfStore.currentPage,
      workspaceRoot: workspaceStore.root?.id
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(workspaceStore)
        .environmentObject(tabStore)
        .environmentObject(pdfStore)
        .environmentObject(pdfBookmarksStore)
        .environmentObject(imageStore)
        .environmentObject(annotationStore)
        .environmentObject(readingPositionStore)
        .environmentObject(favoritesStore)
        .environmentObject(recentsStore)
        .environmentObject(stateStore)
        .environmentObject(settingsStore)
        .environmentObject(searchStore)
        .environmentObject(backlinksStore)
        .environmentObject(aiSettingsStore)
        .environmentObject(aiKeyStore)
        .environmentObject(externalOpen)
        .frame(minWidth: 1080, minHeight: 640)
        // Finder 双击 / Open With / 拖 Dock 打开文件：恢复现场就绪前入队，就绪后路由
        .onOpenURL { url in
          externalOpen.handle(url)
        }
        .onAppear {
          // 重命名/移动成功（含撤销/重做链）→ 标签页路径跟随；
          // 撤销在 WorkspaceStore 内闭环、不经过视图层，需在 Store 层统一通知
          workspaceStore.onFileMoved = { [weak tabStore] oldURL, newURL in
            tabStore?.fileDidMove(from: oldURL, to: newURL)
          }
        }
    }
    .defaultSize(width: 1380, height: 900)
    .commands {
      CommandGroup(after: .newItem) {
        // 命令面板（FR-6.3 ⌘O）；「打开文件夹」让位改 ⌘⇧O
        Button("命令面板…") {
          workspaceStore.isCommandPalettePresented = true
        }
        .keyboardShortcut("o")
        Button("打开文件夹…") {
          workspaceStore.openFolderPanel()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        Button("快速打开…") {
          workspaceStore.isQuickOpenPresented = true
        }
        .keyboardShortcut("p")
        // 全文搜索（FR-6.2 ⌘⇧F）
        Button("全文搜索…") {
          workspaceStore.isFullTextSearchPresented = true
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        Divider()
        // 导出当前 md（FR-2.9）/ 导出全部标注（FR-4.8，导出后打开目标笔记）
        Button("导出为 PDF") {
          if let store = tabStore.activeEditorStore {
            MarkdownExportFlow.run(.pdf, store: store)
          }
        }
        .disabled(tabStore.activeEditorStore == nil)
        Button("导出为 HTML") {
          if let store = tabStore.activeEditorStore {
            MarkdownExportFlow.run(.html, store: store)
          }
        }
        .disabled(tabStore.activeEditorStore == nil)
        Button("导出全部标注为 Markdown…") {
          if let url = AnnotationExportFlow.run(store: annotationStore) {
            tabStore.open(url: url)
          }
        }
        .disabled(annotationStore.currentFileURL == nil)
        Divider()
        // 只读标注模式（FR-4.7）：逐文件切换，标注存同名 sidecar JSON
        Toggle(
          "只读标注模式",
          isOn: Binding(
            get: { annotationStore.isSidecarMode },
            set: { annotationStore.setSidecarMode($0) }
          )
        )
        .disabled(annotationStore.currentFileURL == nil)
      }
      CommandGroup(replacing: .saveItem) {
        Button("保存") {
          tabStore.activeEditorStore?.flushPendingSave()
        }
        .keyboardShortcut("s")
      }
      // 缩放快捷键（FR-3.2）：⌘= 放大、⌘- 缩小、⌘0 实际大小（PDF / 图片均可）
      CommandGroup(after: .toolbar) {
        Button("放大") {
          zoomAction { $0.zoomIn() }
        }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(!zoomable)
        Button("缩小") {
          zoomAction { $0.zoomOut() }
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(!zoomable)
        Button("实际大小") {
          zoomAction { $0.resetZoom() }
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(!zoomable)
      }
      // PDF 页内搜索（FR-3.4）：⌘F 查找栏、⌘G 下一个、⇧⌘G 上一个
      CommandGroup(after: .textEditing) {
        // 复制为带回链的引用块（FR-5.2）：引用块 + 页码回链，粘贴进 md 可跳转
        Button("复制为带回链的引用") {
          copyPDFSelectionAsQuote()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(tabStore.activeGroup.activeTab?.kind != .pdf || !pdfStore.hasSelection)
        Button("在文档中查找…") {
          pdfStore.presentFindBar()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(tabStore.activeGroup.activeTab?.kind != .pdf)
        Button("查找下一个") {
          pdfStore.findNext()
        }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(!pdfStore.isFindBarVisible)
        Button("查找上一个") {
          pdfStore.findPrevious()
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(!pdfStore.isFindBarVisible)
      }
    }

    // 设置（FR-7.2；⌘,）
    Settings {
      SettingsView()
        .environmentObject(settingsStore)
        .environmentObject(aiSettingsStore)
        .environmentObject(aiKeyStore)
        .environmentObject(defaultHandlerService)
    }
  }
}
