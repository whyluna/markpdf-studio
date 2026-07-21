import SwiftUI

/// 标签组面板（FR-1.4）：标签栏 + 激活标签内容区。
/// 点击内容区激活该组（分栏时窗口工具栏/面板跟随）。
struct TabGroupPane: View {
  @ObservedObject var group: TabGroup
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var pdfStore: PDFReaderStore

  var body: some View {
    VStack(spacing: 0) {
      TabBarView(group: group)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
          tabStore.activeGroupID = group.id
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let tab = group.activeTab {
      switch tab.kind {
      case .markdown:
        MarkdownTabView(store: group.editorStore(for: tab))
      case .pdf:
        if let url = tab.url {
          PDFReaderView(url: url)
            // 页内查找栏（FR-3.4）：⌘F 置 isFindBarVisible 后浮于 PDF 顶部
            .overlay(alignment: .top) {
              if pdfStore.isFindBarVisible {
                PDFFindBarView()
                  .frame(maxWidth: .infinity)
              }
            }
        }
      case .image:
        if let url = tab.url {
          ImagePreviewView(url: url)
        }
      default:
        EmptyTabPlaceholder()
      }
    } else {
      EmptyTabPlaceholder()
    }
  }
}

/// 空组占位（分栏后等待拖入标签）
private struct EmptyTabPlaceholder: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "rectangle.leadinghalf.filled")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("将标签拖到此处")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Markdown 标签内容：把标签自己的 EditorStore 接入内核视图
struct MarkdownTabView: View {
  @ObservedObject var store: EditorStore
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var stateStore: WorkspaceStateStore
  @EnvironmentObject private var workspaceStore: WorkspaceStore
  @EnvironmentObject private var settings: SettingsStore
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var pdfStore: PDFReaderStore

  var body: some View {
    MarkdownEditorView(
      text: $store.text,
      documentID: store.currentFileURL,
      mode: store.mode,
      theme: colorScheme == .dark ? .dark : .light,
      scrollToLine: store.pendingScrollLine,
      // FR-1.6：载入即恢复上次编辑行；光标变化经内核防抖上报回存
      initialLine: store.currentFileURL.flatMap { stateStore.cursorLine(for: $0) },
      // FR-2.5：图片粘贴/拖拽存工作区 assets/
      workspaceRoot: workspaceStore.root?.id,
      // FR-7.2：编辑器排版设置
      fontCSS: settings.editorFont.cssFontStack ?? "",
      fontSize: settings.editorFontSize,
      lineHeight: settings.editorLineHeight,
      // FR-2.10：打字机/专注模式
      typewriter: settings.typewriterMode,
      focusMode: settings.focusMode,
      onContentChanged: { newText in
        store.contentDidChange(newText)
      },
      onOutlineChanged: { items in
        store.outline = items
      },
      onScrollHandled: {
        store.didHandleScroll()
      },
      onCursorMoved: { line in
        store.cursorDidMove(to: line)
      },
      // FR-5.3：文件回链打开（pdf 带页码则跳转并闪烁）
      onOpenFileLink: { url, page in
        tabStore.open(url: url)
        if let page {
          pdfStore.pendingPage = page
          pdfStore.pendingFlash = true
        }
      }
    )
  }
}

#Preview {
  TabGroupPane(group: TabGroup())
    .environmentObject(TabStore())
    .environmentObject(WorkspaceStateStore())
    .environmentObject(SettingsStore())
    .environmentObject(PDFReaderStore())
}
