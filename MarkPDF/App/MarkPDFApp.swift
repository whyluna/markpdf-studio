import SwiftUI

@main
struct MarkPDFApp: App {
  @StateObject private var workspaceStore = WorkspaceStore()
  @StateObject private var tabStore = TabStore()
  @StateObject private var pdfStore = PDFReaderStore()
  @StateObject private var pdfBookmarksStore = PDFBookmarksStore()
  @StateObject private var imageStore = ImagePreviewStore()
  @StateObject private var annotationStore = PDFAnnotationStore()
  @StateObject private var readingPositionStore = PDFReadingPositionStore()
  @StateObject private var favoritesStore = FavoritesStore()
  @StateObject private var recentsStore = RecentFilesStore()
  @StateObject private var stateStore = WorkspaceStateStore()
  @StateObject private var settingsStore = SettingsStore()
  @StateObject private var searchStore = SearchStore()

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
        .frame(minWidth: 1080, minHeight: 640)
    }
    .defaultSize(width: 1380, height: 900)
    .commands {
      CommandGroup(after: .newItem) {
        Button("打开文件夹…") {
          workspaceStore.openFolderPanel()
        }
        .keyboardShortcut("o")
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
        Button("在文档中查找…") {
          pdfStore.isFindBarVisible = true
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
    }
  }
}
