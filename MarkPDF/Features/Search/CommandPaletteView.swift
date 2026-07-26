import SwiftUI

/// 命令面板的一条命令（FR-6.3）
struct AppCommand: Identifiable {
  let id: String
  /// 显示标题（如「导出为 PDF」）
  let title: String
  /// 副标题/分组（如「导出」「视图」）
  let section: String
  /// 快捷键展示（如 ⌘S；仅显示用）
  let shortcut: String?
  /// 拼音首字母（匹配用，预计算）
  let pinyin: String
  /// 当前是否可用（面板打开时求值）
  let isEnabled: () -> Bool
  let action: () -> Void

  init(
    id: String, title: String, section: String, shortcut: String? = nil,
    isEnabled: @escaping () -> Bool = { true }, action: @escaping () -> Void
  ) {
    self.id = id
    self.title = title
    self.section = section
    self.shortcut = shortcut
    self.pinyin = PinyinInitials.of(title)
    self.isEnabled = isEnabled
    self.action = action
  }
}

/// 命令面板（FR-6.3；⌘O）：全部功能可搜索执行，支持拼音首字母匹配。
struct CommandPaletteView: View {
  let commands: [AppCommand]
  let onDismiss: () -> Void

  @State private var query = ""
  @State private var selectedIndex = 0
  /// 匹配结果缓存：仅在 query 变化时重算——body 单帧内多处读取 results，
  /// 计算属性写法会对全部命令重复模糊匹配 + 排序。
  /// commands 在模态面板打开期间不会实质变化（遮罩阻断交互），每次打开都重新构造本视图
  @State private var results: [AppCommand]

  private static let maxResults = 50

  init(commands: [AppCommand], onDismiss: @escaping () -> Void) {
    self.commands = commands
    self.onDismiss = onDismiss
    _results = State(initialValue: Self.computeResults(query: "", commands: commands))
  }

  /// 结果计算（提纯便于单测）：空查询取前 maxResults 条可用命令；否则按分降序，
  /// 同分按标题升序 tiebreak（无 tiebreak 时同分元素输入过程中行序抖动）
  static func computeResults(
    query: String,
    commands: [AppCommand],
    maxResults: Int = Self.maxResults
  ) -> [AppCommand] {
    let enabled = commands.filter { $0.isEnabled() }
    if query.isEmpty {
      return Array(enabled.prefix(maxResults))
    }
    // 查询正规化只做一次，全体命令复用
    let prepared = FuzzyMatcher.prepare(query)
    return
      enabled
      .compactMap { command -> (AppCommand, Int)? in
        // 标题与拼音首字母双通道模糊匹配，取高分
        let byTitle = FuzzyMatcher.match(prepared, in: command.title)
        let byPinyin = FuzzyMatcher.match(prepared, in: command.pinyin)
        guard byTitle != nil || byPinyin != nil else { return nil }
        return (command, max(byTitle?.score ?? 0, byPinyin?.score ?? 0))
      }
      .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
      .prefix(maxResults)
      .map { $0.0 }
  }

  var body: some View {
    VStack(spacing: 0) {
      CommandSearchField(
        text: $query,
        placeholder: String(localized: "输入命令或拼音首字母…"),
        onMoveUp: { selectedIndex = clampedSelectionIndex(selectedIndex - 1, count: results.count) },
        onMoveDown: { selectedIndex = clampedSelectionIndex(selectedIndex + 1, count: results.count) },
        onSubmit: runSelected,
        onCancel: onDismiss
      )
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      if results.isEmpty {
        Text("无匹配命令")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                resultRow(command, selected: index == selectedIndex)
                  .id(index)
                  .onTapGesture {
                    selectedIndex = index
                    runSelected()
                  }
              }
            }
            .padding(6)
          }
          .onChange(of: selectedIndex) { index in
            proxy.scrollTo(index, anchor: .center)
          }
        }
      }
    }
    .frame(width: 560, height: 420)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
    .onChange(of: query) { _ in
      selectedIndex = 0
      results = Self.computeResults(query: query, commands: commands)
    }
  }

  private func resultRow(_ command: AppCommand, selected: Bool) -> some View {
    HStack(spacing: 8) {
      Text(command.title)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text(command.section)
        .font(.caption)
        .foregroundStyle(.tertiary)
      if let shortcut = command.shortcut {
        Text(shortcut)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    .contentShape(RoundedRectangle(cornerRadius: 7))
  }

  private func runSelected() {
    guard results.indices.contains(selectedIndex) else { return }
    let command = results[selectedIndex]
    onDismiss()
    command.action()
  }
}

#Preview {
  CommandPaletteView(
    commands: [
      AppCommand(id: "save", title: "保存", section: "文件", shortcut: "⌘S") {},
      AppCommand(id: "export-pdf", title: "导出为 PDF", section: "导出") {},
      AppCommand(id: "split", title: "左右分栏", section: "视图") {},
    ],
    onDismiss: {}
  )
}
