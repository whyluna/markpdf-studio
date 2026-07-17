import SwiftUI

@main
struct MarkPDFApp: App {
  @StateObject private var workspaceStore = WorkspaceStore()
  @StateObject private var editorStore = EditorStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(workspaceStore)
        .environmentObject(editorStore)
        .frame(minWidth: 1080, minHeight: 640)
    }
    .defaultSize(width: 1380, height: 900)
    .commands {
      CommandGroup(after: .newItem) {
        Button("打开文件夹…") {
          workspaceStore.openFolderPanel()
        }
        .keyboardShortcut("o")
      }
    }
  }
}
