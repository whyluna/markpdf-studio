import SwiftUI

/// 工作区文件树侧栏（FR-1.1）：工作区头部 + 可展开树 + 空状态引导。
struct FileTreeView: View {
  @EnvironmentObject private var store: WorkspaceStore

  var body: some View {
    Group {
      if let root = store.root {
        treeContent(root)
      } else {
        emptyState
      }
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
        List(selection: $store.selection) {
          OutlineGroup(root.children ?? [], children: \.children) { node in
            Label(node.name, systemImage: node.iconName)
              .lineLimit(1)
              .truncationMode(.middle)
              .tag(node)
          }
        }
        .listStyle(.sidebar)
      }
    }
  }

  /// 顶部：工作区名 + 切换文件夹
  private func header(_ root: FileNode) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "folder.fill")
        .foregroundStyle(.secondary)
      Text(root.name)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Button(action: store.openFolderPanel) {
        Image(systemName: "arrow.triangle.2.circlepath")
      }
      .buttonStyle(.borderless)
      .help("切换工作区文件夹…")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
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
}
