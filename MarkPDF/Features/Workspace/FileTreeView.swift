import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 工作区文件树侧栏（FR-1.1）：工作区头部 + 可展开树 + 空状态引导。
/// FR-1.2：右键菜单（新建/重命名/删除/Finder 显示）、行内命名、拖拽移动、Cmd+Z 撤销。
struct FileTreeView: View {
  @EnvironmentObject private var store: WorkspaceStore
  @EnvironmentObject private var tabStore: TabStore
  @EnvironmentObject private var favoritesStore: FavoritesStore
  @EnvironmentObject private var recentsStore: RecentFilesStore
  @Environment(\.undoManager) private var undoManager

  /// 行内命名状态：新建后为默认名节点命名，或对既有节点重命名
  @State private var naming: NamingState?
  @FocusState private var namingFocused: Bool

  private struct NamingState: Equatable {
    let node: FileNode
    var draft: String
  }

  /// 打开文件（行点击手势触发，事件阶段发布状态，合法无警告）。
  /// 注意：不要用 List(selection:) 绑定驱动——macOS 上该绑定在视图更新途中写回，
  /// 追加发布会被 "Publishing changes from within view updates" 吞掉（文件打不开）。
  private func open(_ node: FileNode) {
    store.selection = node
    tabStore.open(node)
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
        // 自绘递归树：文件夹行整行点击展开/收起，文件行任意位置点击打开
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            treeRows(root.children ?? [], depth: 0)
          }
          .padding(.vertical, 4)
          // FR-1.5：收藏 / 最近打开分区（对齐设计稿 .sec）
          collectionSection(title: "收藏", urls: favoritesStore.files(forRoot: root.id)) { url in
            favoritesStore.remove(url, forRoot: root.id)
          }
          collectionSection(title: "最近打开", urls: recentsStore.files(forRoot: root.id), onRemove: nil)
        }
      }
    }
  }

  @ViewBuilder
  private func treeRows(_ nodes: [FileNode], depth: Int) -> some View {
    ForEach(nodes) { node in
      VStack(alignment: .leading, spacing: 0) {
        rowContent(node, depth: depth)
        if node.isFolder, !store.collapsedFolders.contains(node.id) {
          // AnyView 擦除类型：递归 some View 无法自我推断
          AnyView(treeRows(node.children ?? [], depth: depth + 1))
        }
      }
    }
  }

  @ViewBuilder
  private func rowContent(_ node: FileNode, depth: Int) -> some View {
    HStack(spacing: 4) {
      // 文件夹雪佛龙（点击行任意位置均可展开/收起）
      if node.isFolder {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(store.collapsedFolders.contains(node.id) ? 0 : 90))
          .frame(width: 12)
      } else {
        Spacer()
          .frame(width: 12)
      }
      if naming?.node == node {
        namingField
      } else {
        Label(node.name, systemImage: node.iconName)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .padding(.leading, 8 + CGFloat(depth) * 14)
    .padding(.trailing, 8)
    .padding(.vertical, 4.5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(store.selection == node ? Color.accentColor : .primary)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(store.selection == node ? Color.accentColor.opacity(0.15) : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      guard naming?.node != node else { return }
      if node.isFolder {
        store.toggleFolderCollapsed(node.id)
      } else {
        open(node)
      }
    }
    .contextMenu { nodeMenu(node) }
    .onDrag { NSItemProvider(object: node.id as NSURL) }
    .onDrop(of: [.fileURL], isTargeted: nil) { _ in
      node.isFolder ? handleDrop(toFolder: node) : false
    }
  }

  /// 行内命名输入框：Enter 提交，Esc 取消，点击别处（焦点丢失）也提交
  private var namingField: some View {
    TextField("名称", text: namingDraft)
      .textFieldStyle(.plain)
      .labelsHidden()
      .focused($namingFocused)
      .onAppear { namingFocused = true }
      .onSubmit(commitNaming)
      .onExitCommand(perform: cancelNaming)
      .onChange(of: namingFocused) { focused in
        // 焦点离开即提交（对齐 Finder 重命名手感）；cancel 时 naming 已清空，guard 拦截
        if !focused { commitNaming() }
      }
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

  // MARK: - 收藏 / 最近打开分区（FR-1.5）

  /// 文件集合分区：标题 + 文件行（点击打开）；已删除的文件不显示
  @ViewBuilder
  private func collectionSection(title: String, urls: [URL], onRemove: ((URL) -> Void)?) -> some View {
    let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    if !existing.isEmpty {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
      ForEach(existing, id: \.self) { url in
        HStack(spacing: 4) {
          Spacer()
            .frame(width: 12)
          Label(url.lastPathComponent, systemImage: FileNode.kind(for: url, isDirectory: false).iconName)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
          tabStore.open(url: url)
        }
        .contextMenu {
          if let onRemove {
            Button("从「\(title)」移除") { onRemove(url) }
          }
        }
      }
    }
  }

  // MARK: - 右键菜单

  @ViewBuilder
  private func nodeMenu(_ node: FileNode) -> some View {
    if node.isFolder {
      Button("新建 Markdown 文件") { createMarkdown(in: node.id) }
      Button("新建文件夹") { createFolder(in: node.id) }
      Divider()
    } else if let root = store.root {
      // 收藏切换（FR-1.5）
      Button(favoritesStore.contains(node.id, forRoot: root.id) ? "移除收藏" : "加入收藏") {
        favoritesStore.toggle(node.id, forRoot: root.id)
      }
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
    // 标签迁移由 store.onFileMoved 统一回调（覆盖撤销/重做链），视图层不再重复通知
    _ = store.rename(state.node, to: name, undo: undoManager)
  }

  private func cancelNaming() {
    naming = nil
  }

  private func trash(_ node: FileNode) {
    store.trash(node)
    tabStore.fileWasTrashed(node.id)
  }

  private func handleDrop(toFolder folder: FileNode) -> Bool {
    // performDrop 必须同步返回接受/拒绝，而 NSItemProvider 只能异步取 URL——
    // 改从拖拽 pasteboard 同步读文件 URL 先校验（同一次拖拽会话内有效）：
    // 查不到 node（工作区外文件）明确拒绝，原实现静默丢弃却显示拖放成功
    guard let objects = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: nil),
      !objects.isEmpty
    else { return false }
    // 去重后逐个解析为树节点（原实现只处理 providers.first，多选拖入会丢其余项）
    var seen = Set<URL>()
    let nodes = objects.compactMap { $0 as? URL }.filter { seen.insert($0).inserted }
      .compactMap { store.node(for: $0) }
    guard !nodes.isEmpty else { return false }
    for node in nodes {
      // 标签迁移由 store.onFileMoved 统一回调，视图层不再重复通知
      _ = store.move(node, toFolder: folder.id, undo: undoManager)
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
    .environmentObject(FavoritesStore())
    .environmentObject(RecentFilesStore())
}
