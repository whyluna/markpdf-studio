import SwiftUI

/// 变更提案卡片（FR-AI.5/6）：文件清单 + 逐块勾选 + 应用/拒绝/撤销。
/// 文件行点击 → 全宽 diff 审查 sheet：待审时审查；已应用后回看当时改动
///（并切到该文件标签——新建文件尤其需要看到落在哪）
struct AIChangeCardView: View {
  let sealed: AIChangeStore.SealedChangeSet
  @ObservedObject var store: AIChangeStore
  /// 流式中禁用按钮（避免应用与提案并发）
  let isBusy: Bool
  @State private var isWorking = false
  @State private var sheetChange: AIFileChange?

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      header
      ForEach(sealed.set.changes) { change in
        changeRow(change)
      }
      footer
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    .task(id: sealed.id) {
      await store.prepareReviewsIfNeeded(sealed.id)
    }
    .sheet(item: $sheetChange) { change in
      AIChangeDiffSheet(
        sealed: store.changeSet(id: sealed.id) ?? sealed,
        change: change,
        store: store,
        onOpenFile: { store.openChangeFile($0) }
      )
    }
  }

  private var header: some View {
    Text("AI 变更提案 · \(sealed.set.changes.count) 个文件")
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
  }

  // MARK: - 文件行

  private func changeRow(_ change: AIFileChange) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Button {
        if case .applied = sealed.status {
          // 已应用：切到该文件标签（新建文件落到前台）+ 回看本批改动
          store.openChangeFile(change)
        }
        sheetChange = change
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: icon(for: change.kind))
            .font(.system(size: 10))
            .foregroundStyle(.tint)
            .frame(width: 13)
          Text(change.path)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(change.path)
          Spacer(minLength: 4)
          Text(detail(for: change))
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if case .editFile = change.kind, let review = sealed.reviews[change.id] {
        unitSummary(review, change: change)
      }
    }
  }

  /// 逐变更段勾选条：段胶囊（点击切换）+ 全无
  @ViewBuilder
  private func unitSummary(_ review: AIChangeStore.FileReview, change: AIFileChange) -> some View {
    if !review.units.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        // 自适应网格折行：胶囊统一最小宽度，排不下自动换行（自定义 Layout 在
        // 面板容器里协商异常曾致卡片塌缩，弃用）
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 42), spacing: 4)],
          alignment: .leading,
          spacing: 4
        ) {
          ForEach(Array(review.units.enumerated()), id: \.element.id) { index, unit in
            unitPill(index: index, unit: unit, change: change)
          }
          if sealed.status == .pending {
            Button("无") { store.setAllUnits(sealed.id, changeID: change.id, accepted: false) }
              .font(.system(size: 10))
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
          }
        }
        if review.skippedEditCount > 0 {
          Text("\(review.skippedEditCount) 处提案已因文本变化丢弃")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.leading, 19)
    }
  }

  private func unitPill(index: Int, unit: AIChangeStore.ReviewUnit, change: AIFileChange) -> some View {
    Button {
      guard sealed.status == .pending else { return }
      store.toggleUnit(sealed.id, changeID: change.id, unitID: unit.id)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: unit.isAccepted ? "checkmark" : "xmark")
          .font(.system(size: 7, weight: .bold))
        Text("\(index + 1)")
          .font(.system(size: 10, design: .monospaced))
        Text("±\(unit.changeCount)")
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 2)
      .background(
        (unit.isAccepted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07)),
        in: Capsule()
      )
      .foregroundStyle(unit.isAccepted ? Color.accentColor : Color.secondary)
      .help(unit.isAccepted ? "点击取消该变更段" : "点击接受该变更段")
    }
    .buttonStyle(.plain)
    .disabled(sealed.status != .pending)
  }

  private func icon(for kind: AIFileChange.Kind) -> String {
    switch kind {
    case .createFile: return "doc.badge.plus"
    case .editFile: return "pencil.line"
    case .createFolder: return "folder.badge.plus"
    }
  }

  private func detail(for change: AIFileChange) -> String {
    if let review = sealed.reviews[change.id], review.kind == .editFile {
      return review.units.isEmpty
        ? String(localized: "修改 · 文本已变化")
        : String(localized: "修改 \(review.acceptedUnitCount)/\(review.units.count) 处")
    }
    switch change.kind {
    case .createFile: return String(localized: "新建 · \(change.content.count) 字")
    case .editFile: return String(localized: "修改 · \(change.edits.count) 块")
    case .createFolder: return String(localized: "新建文件夹")
    }
  }

  // MARK: - 状态脚注

  @ViewBuilder
  private var footer: some View {
    switch sealed.status {
    case .applying:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("正在应用…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .pending:
      HStack(spacing: 8) {
        Button {
          guard !isWorking else { return }
          isWorking = true
          Task { await store.apply(sealed.id); isWorking = false }
        } label: {
          if isWorking {
            ProgressView().controlSize(.mini)
          } else {
            Text("应用勾选的变更")
          }
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .disabled(isBusy || isWorking)

        Button("拒绝") {
          store.reject(sealed.id)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(isBusy || isWorking)

        Text("应用前不会写入任何文件")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    case .applied(let summary):
      VStack(alignment: .leading, spacing: 4) {
        Text(summary)
          .font(.caption2)
          .foregroundStyle(.secondary)
        if sealed.checkpoint?.isEmpty == false {
          Button {
            guard !isWorking else { return }
            isWorking = true
            Task { await store.undo(sealed.id); isWorking = false }
          } label: {
            if isWorking {
              ProgressView().controlSize(.mini)
            } else {
              Label("撤销本次变更", systemImage: "arrow.uturn.backward")
            }
          }
          .controlSize(.small)
          .disabled(isBusy || isWorking)
        }
      }
    case .rejected:
      Text("已拒绝（未写入任何文件）")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    case .undone:
      Text("已撤销（新建项已移入废纸篓）")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}

#Preview("待审查") {
  AIChangeCardView(
    sealed: AIChangeStore.SealedChangeSet(
      set: {
        var set = AIChangeSet()
        set.changes = [
          AIFileChange(kind: .createFile, path: "笔记/读书笔记.md", content: "# 笔记", edits: []),
          AIFileChange(kind: .editFile, path: "README.md", content: "", edits: [
            AIFileChange.TextEdit(oldText: "旧", newText: "新"),
          ]),
        ]
        return set
      }()
    ),
    store: AIChangeStore(),
    isBusy: false
  )
  .frame(width: 300)
  .padding()
}

#Preview("已应用") {
  AIChangeCardView(
    sealed: {
      var set = AIChangeSet()
      set.changes = [AIFileChange(kind: .createFile, path: "笔记/读书笔记.md", content: "# 笔记", edits: [])]
      return AIChangeStore.SealedChangeSet(set: set, status: .applied("已新建 笔记/读书笔记.md"))
    }(),
    store: AIChangeStore(),
    isBusy: false
  )
  .frame(width: 300)
  .padding()
}
