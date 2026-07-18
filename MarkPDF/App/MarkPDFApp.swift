import SwiftUI

@main
struct MarkPDFApp: App {
  @StateObject private var workspaceStore = WorkspaceStore()
  @StateObject private var editorStore = EditorStore()
  @StateObject private var pdfStore = PDFReaderStore()
  @StateObject private var pdfBookmarksStore = PDFBookmarksStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(workspaceStore)
        .environmentObject(editorStore)
        .environmentObject(pdfStore)
        .environmentObject(pdfBookmarksStore)
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
      }
      CommandGroup(replacing: .saveItem) {
        Button("保存") {
          editorStore.flushPendingSave()
        }
        .keyboardShortcut("s")
      }
      // PDF 缩放快捷键（FR-3.2）：⌘= 放大、⌘- 缩小、⌘0 实际大小
      CommandGroup(after: .toolbar) {
        Button("放大") {
          pdfStore.zoomIn()
        }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(workspaceStore.selection?.kind != .pdf)
        Button("缩小") {
          pdfStore.zoomOut()
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(workspaceStore.selection?.kind != .pdf)
        Button("实际大小") {
          pdfStore.resetZoom()
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(workspaceStore.selection?.kind != .pdf)
      }
    }
  }
}
