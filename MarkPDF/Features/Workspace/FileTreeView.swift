import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 工作区文件树侧栏（FR-1.1）：工作区头部 + 可展开树 + 空状态引导。
/// FR-1.2：右键菜单（新建/重命名/删除/Finder 显示）、行内命名、拖拽移动、Cmd+Z 撤销。
struct FileTreeView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @EnvironmentObject private var tabStore: TabStore
  @Environment(\.undoManager) private var undoManager

  /// 行内命名状态：新建后为默认名节点命名，或对既有节点重命名
  @State private var naming: NamingState?
  @FocusState private var namingFocused: Bool

  private struct NamingState: Equatable {
    let node: FileNode
    var draft: String
  }

  /// 选中绑定：在事件阶段直接于当前标签组打开文件（FR-1.4）。
  /// 不用 onChange + 异步——那会在视图更新途中改 @Published，
  /// 触发 "Publishing changes from within view updates" 未定义行为。
  private var selection: Binding<FileNode?> {
    Binding(
      get: { store.selection },
      set: { node in
        store.selection = node
        if let node, node.kind != .folder {
          tabStore.open(node)
        }
      }
    )
  }

  var body: some View {
    Group {
      if let root = store.root {
        treeContent(root)
      } else {
        emptyState
      }
    }
    .alert(
      "文件操作失败",
      isPresented: Binding(
        get: { store.lastError != nil },
        set: { if !$0 { store.lastError = nil } }
      )
    ) {
      Button("好") { store.lastError = nil }
    } message: {
      Text(store.lastError ?? "")
    }
  }

  // MARK: - 树主体

  private func treeContent(_ root: FileNode) -> some View {
    VStack(spacing: 0) {
      header(root)
      Divider()
      if store.isLoading {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if root.children?.isEmpty ?? true {
        Text("此文件夹中没有\nMarkdown / PDF / 图片")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: selection) {
          OutlineGroup(root.children ?? [], children: \.children) { node in
            rowContent(node)
              .tag(node)
          }
        }
        .listStyle(.sidebar)
      }
    }
  }

  @ViewBuilder
  private func rowContent(_ node: FileNode) -> some View {
    if naming?.node == node {
      namingField
    } else {
      Label(node.name, systemImage: node.iconName)
        .lineLimit(1)
        .truncationMode(.middle)
        .contextMenu { nodeMenu(node) }
        .onDrag { NSItemProvider(object: node.id as NSURL) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
          node.isFolder ? handleDrop(providers, toFolder: node) : false
        }
    }
  }

  /// 行内命名输入框：Enter 提交，Esc 取消
  private var namingField: some View {
    TextField("名称", text: namingDraft)
      .textFieldStyle(.plain)
      .labelsHidden()
      .focused($namingFocused)
      .onAppear { namingFocused = true }
      .onSubmit(commitNaming)
      .onExitCommand(perform: cancelNaming)
  }

  private var namingDraft: Binding<String> {
    Binding(
      get: { naming?.draft ?? "" },
      set: { naming?.draft = $0 }
    )
  }

  /// 顶部：工作区名 + 新建 + 切换文件夹
  private func header(_ root: FileNode) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "folder.fill")
        .foregroundStyle(.secondary)
      Text(root.name)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Menu {
        Button("新建 Markdown 文件") { createMarkdown(in: root.id) }
        Button("新建文件夹") { createFolder(in: root.id) }
      } label: {
        Image(systemName: "plus")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 20)
      .help("新建文件 / 文件夹")
      Button(action: store.openFolderPanel) {
        Image(systemName: "arrow.triangle.2.circlepath")
      }
      .buttonStyle(.borderless)
      .help("切换工作区文件夹…")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - 右键菜单

  @ViewBuilder
  private func nodeMenu(_ node: FileNode) -> some View {
    if node.isFolder {
      Button("新建 Markdown 文件") { createMarkdown(in: node.id) }
      Button("新建文件夹") { createFolder(in: node.id) }
      Divider()
    }
    Button("重命名") { naming = NamingState(node: node, draft: node.name) }
    Button("删除") { trash(node) }
    Divider()
    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([node.id]) }
  }

  // MARK: - 操作

  private func createMarkdown(in folder: URL) {
    guard let url = store.createMarkdown(in: folder, undo: undoManager) else { return }
    naming = NamingState(
      node: FileNode(id: url, name: url.lastPathComponent, kind: .markdown),
      draft: url.lastPathComponent
    )
  }

  private func createFolder(in folder: URL) {
    guard let url = store.createFolder(in: folder, undo: undoManager) else { return }
    naming = NamingState(
      node: FileNode(id: url, name: url.lastPathComponent, kind: .folder),
      draft: url.lastPathComponent
    )
  }

  private func commitNaming() {
    guard let state = naming else { return }
    var name = state.draft.trimmingCharacters(in: .whitespaces)
    naming = nil
    guard !name.isEmpty, name != state.node.name else { return }
    // 未输入扩展名时沿用原扩展名（避免 md 改名后类型丢失、从树中消失）
    let ext = state.node.id.pathExtension
    if (name as NSString).pathExtension.isEmpty, !ext.isEmpty {
      name += "." + ext
    }
    if let newURL = store.rename(state.node, to: name, undo: undoManager) {
      tabStore.fileDidMove(from: state.node.id, to: newURL)
    }
  }

  private func cancelNaming() {
    naming = nil
  }

  private func trash(_ node: FileNode) {
    store.trash(node)
    tabStore.fileWasTrashed(node.id)
  }

  private func handleDrop(_ providers: [NSItemProvider], toFolder folder: FileNode) -> Bool {
    guard let provider = providers.first else { return false }
    provider.loadObject(ofClass: NSURL.self) { object, _ in
      guard let url = object as? NSURL as URL? else { return }
      DispatchQueue.main.async {
        guard let dragged = store.node(for: url) else { return }
        if let newURL = store.move(dragged, toFolder: folder.id, undo: undoManager) {
          tabStore.fileDidMove(from: url, to: newURL)
        }
      }
    }
    return true
  }

  // MARK: - 空状态

  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "folder.badge.plus")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text("打开一个文件夹\n作为工作区")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("打开文件夹…", action: store.openFolderPanel)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  FileTreeView()
    .environmentObject(WorkspaceStore())
    .environmentObject(TabStore())
}
