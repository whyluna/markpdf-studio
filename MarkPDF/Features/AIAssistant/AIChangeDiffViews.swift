import SwiftUI

/// 统一 diff 渲染（FR-AI.6）：hunk 头 + 带行号的红删绿增行（等宽字体）。
/// 勾选控制在编辑块头部（块 = 模型的一个 S/R 提案），行级只读展示
struct DiffTextView: View {
  let hunks: [LineDiff.Hunk]
  /// 隐藏 @@ 头（块内小 diff / 整篇新增展示时可关）
  var showsHunkHeaders = true

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(hunks) { hunk in
        hunkView(hunk)
      }
    }
  }

  private func hunkView(_ hunk: LineDiff.Hunk) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if showsHunkHeaders {
        Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.tertiary)
          .padding(.vertical, 2)
      }
      ForEach(hunk.lines) { line in
        lineRow(line)
      }
    }
  }

  private func lineRow(_ line: LineDiff.Line) -> some View {
    HStack(spacing: 0) {
      Text(line.oldNumber.map(String.init) ?? "")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: 34, alignment: .trailing)
      Text(line.newNumber.map(String.init) ?? "")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: 34, alignment: .trailing)
      Text(line.kind == .added ? "+" : line.kind == .removed ? "-" : " ")
        .font(.system(size: 11, design: .monospaced))
        .frame(width: 12)
      Text(line.text.isEmpty ? " " : line.text)
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 0.5)
    .background(background(for: line.kind))
  }

  @ViewBuilder
  private func background(for kind: LineDiff.Kind) -> some View {
    switch kind {
    case .added: Color.green.opacity(0.12)
    case .removed: Color.red.opacity(0.10)
    case .context: Color.clear
    }
  }
}

/// 全宽 diff 审查 sheet（点变更卡片上的文件打开）：逐变更段勾选 + 段内前后对比；
/// 新建文件整篇按新增展示；已应用后为回看模式（勾选冻结，展示当时改动）
struct AIChangeDiffSheet: View {
  let sealed: AIChangeStore.SealedChangeSet
  let change: AIFileChange
  @ObservedObject var store: AIChangeStore
  /// 已应用/已拒绝后提供「打开文件」
  var onOpenFile: ((AIFileChange) -> Void)?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        content
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 680, minHeight: 520)
  }

  private var review: AIChangeStore.FileReview? {
    sealed.reviews[change.id]
  }

  private var isPending: Bool {
    if case .pending = sealed.status { return true }
    return false
  }

  private var header: some View {
    HStack(spacing: 10) {
      // macOS 惯例：关闭在左上角
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .background(Color.primary.opacity(0.06), in: Circle())
      }
      .buttonStyle(.plain)
      .help("关闭（Esc）")
      .keyboardShortcut(.cancelAction)

      Image(systemName: icon)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(change.path)
          .font(.system(size: 13, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(subtitle)
          .font(.system(size: AppTypography.metadata))
          .foregroundStyle(.secondary)
      }
      Spacer()
      if isPending, let review, review.kind == .editFile, !review.units.isEmpty {
        Text("\(review.acceptedUnitCount)/\(review.units.count) 处")
          .font(.system(size: AppTypography.secondary, weight: .medium))
          .foregroundStyle(review.acceptedUnitCount == 0 ? Color.red : Color.accentColor)
        Button("全不选") {
          store.setAllUnits(sealed.id, changeID: change.id, accepted: false)
        }
        .controlSize(.small)
      }
      if case .applied = sealed.status {
        Button("打开文件") { onOpenFile?(change) }
          .controlSize(.small)
      }
    }
    .padding(12)
  }

  private var icon: String {
    switch change.kind {
    case .createFile: return "doc.badge.plus"
    case .editFile: return "pencil.line"
    case .createFolder: return "folder.badge.plus"
    }
  }

  private var subtitle: String {
    switch change.kind {
    case .createFile: return String(localized: "新建文件 · \(change.content.count) 字")
    case .editFile:
      if let review {
        let skipped = review.skippedEditCount
        return skipped > 0
          ? String(localized: "修改 · \(review.units.count) 个变更段（\(skipped) 处提案已因文本变化丢弃）")
          : String(localized: "修改 · \(review.units.count) 个变更段")
      }
      return String(localized: "修改 · \(change.edits.count) 处")
    case .createFolder: return String(localized: "新建文件夹")
    }
  }

  @ViewBuilder
  private var content: some View {
    switch change.kind {
    case .createFile:
      DiffTextView(hunks: [addedContentHunk(change.content)], showsHunkHeaders: false)
    case .editFile:
      if let review {
        if review.units.isEmpty {
          Text("提案的所有修改在封存时已无法匹配当前文件（文本已变化）")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 20)
        } else {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(review.units.enumerated()), id: \.element.id) { index, unit in
              unitView(index: index, unit: unit)
            }
          }
        }
      } else {
        ProgressView()
          .padding(.top, 40)
      }
    case .createFolder:
      Text("将创建文件夹")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 20)
    }
  }

  /// 单个变更段：头部（序号/增删行数/勾选）+ 段内 diff（行号为文件绝对行号）
  private func unitView(index: Int, unit: AIChangeStore.ReviewUnit) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Button {
          guard isPending else { return }
          store.toggleUnit(sealed.id, changeID: change.id, unitID: unit.id)
        } label: {
          HStack(spacing: 5) {
            Image(systemName: unit.isAccepted ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 13))
              .foregroundStyle(unit.isAccepted ? Color.accentColor : Color.secondary)
            Text("变更段 \(index + 1)")
              .font(.system(size: AppTypography.secondary, weight: .medium))
              .foregroundStyle(unit.isAccepted ? Color.primary : Color.secondary)
            Text("±\(unit.changeCount) 行")
              .font(.system(size: AppTypography.metadata))
              .foregroundStyle(.tertiary)
            if !unit.isAccepted {
              Text("已取消")
                .font(.system(size: AppTypography.metadata))
                .foregroundStyle(.tertiary)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPending)
        Spacer()
      }
      .padding(.horizontal, 2)
      DiffTextView(hunks: [unit.hunk])
        .opacity(unit.isAccepted || !isPending ? 1 : 0.45)
    }
    .padding(8)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }

  /// 新建文件内容 → 整篇新增的伪 hunk
  private func addedContentHunk(_ content: String) -> LineDiff.Hunk {
    let lines = LineDiff.splitLines(content).enumerated().map { index, text in
      LineDiff.Line(kind: .added, text: text, oldNumber: nil, newNumber: index + 1)
    }
    return LineDiff.Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: lines.count, lines: lines)
  }
}
