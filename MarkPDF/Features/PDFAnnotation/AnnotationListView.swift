import PDFKit
import SwiftUI

/// 标注列表面板（FR-4.5）：全文档标注一览。
/// 按页/颜色/类型排序；点击定位并闪烁提示；右键改名（写入标注 contents）与删除；
/// 增删改经 Store.revision 实时同步。
struct AnnotationListView: View {
  @EnvironmentObject private var store: PDFAnnotationStore
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @State private var sortOrder: AnnotationSort = .page
  @State private var renamingID: String?
  @State private var renameText = ""
  @FocusState private var renameFocused: Bool

  private var items: [AnnotationItem] {
    sortOrder.sort(store.annotationItems())
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if items.isEmpty {
        Text("暂无标注")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
              row(for: item)
            }
          }
          .padding(8)
        }
      }
    }
  }

  private var header: some View {
    HStack {
      Text("全部标注 · \(items.count)")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.tertiary)
      Spacer()
      Menu {
        ForEach(AnnotationSort.allCases) { order in
          Button {
            sortOrder = order
          } label: {
            if order == sortOrder {
              Label(order.title, systemImage: "checkmark")
            } else {
              Text(order.title)
            }
          }
        }
      } label: {
        Label(sortOrder.title, systemImage: "arrow.up.arrow.down")
          .font(.caption)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private func row(for item: AnnotationItem) -> some View {
    AnnotationRow(
      item: item,
      isRenaming: renamingID == item.id,
      renameText: $renameText,
      renameFocused: $renameFocused,
      onLocate: { locate(item) },
      onRenameCommit: { commitRename(item) },
      onRenameCancel: { renamingID = nil }
    )
    .contextMenu {
      Button(item.name.isEmpty ? "命名" : "改名") {
        renamingID = item.id
        renameText = item.name
        renameFocused = true
      }
      Button("删除", role: .destructive) {
        delete(item)
      }
    }
  }

  /// 点击定位：跳转至标注处并闪烁提示
  private func locate(_ item: AnnotationItem) {
    guard let pdfView = pdfStore.pdfView,
      let first = item.annotations.first,
      let page = first.page
    else { return }
    pdfView.go(to: PDFDestination(
      page: page,
      at: CGPoint(x: first.bounds.minX, y: first.bounds.maxY + 60)
    ))
    AnnotationFlasher.flash(item.annotations, in: pdfView)
  }

  /// 改名提交：写入组内全部标注的 contents（标准属性，第三方阅读器可见）
  private func commitRename(_ item: AnnotationItem) {
    let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    for annotation in item.annotations {
      store.update(annotation) { $0.contents = text }
    }
    renamingID = nil
  }

  private func delete(_ item: AnnotationItem) {
    if renamingID == item.id {
      renamingID = nil
    }
    for annotation in item.annotations {
      if let page = annotation.page {
        store.remove(annotation, from: page)
      }
    }
    if let pdfView = pdfStore.pdfView {
      pdfView.setNeedsDisplay(pdfView.bounds)
    }
  }
}

// MARK: - 列表行

private struct AnnotationRow: View {
  let item: AnnotationItem
  let isRenaming: Bool
  @Binding var renameText: String
  var renameFocused: FocusState<Bool>.Binding
  let onLocate: () -> Void
  let onRenameCommit: () -> Void
  let onRenameCancel: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(Color(nsColor: item.color))
        .frame(width: 10, height: 10)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .padding(.top, 4)
      VStack(alignment: .leading, spacing: 2) {
        if isRenaming {
          TextField("名称", text: $renameText)
            .textFieldStyle(.roundedBorder)
            .focused(renameFocused)
            .onSubmit(onRenameCommit)
            .onExitCommand(perform: onRenameCancel)
        } else {
          Text(item.displayText.isEmpty ? "（无文本）" : item.displayText)
            .font(.system(size: 13))
            .foregroundStyle(item.displayText.isEmpty ? .tertiary : .primary)
            .lineLimit(3)
            .truncationMode(.tail)
        }
        HStack(spacing: 0) {
          Text("\(item.kind.title) · 第 \(item.pageLabel) 页")
            .font(.caption)
            .foregroundStyle(.secondary)
          if !item.name.isEmpty, !isRenaming {
            Text(" · 已命名")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(isHovered ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
    .onTapGesture(perform: onLocate)
    .onHover { isHovered = $0 }
  }
}

// MARK: - 定位闪烁

/// 点击列表定位后的闪烁提示（FR-4.5）：标注范围覆盖层短暂高亮后淡出。
/// 覆盖层不拦截事件；约 1s 后自动移除。
enum AnnotationFlasher {
  static func flash(_ annotations: [PDFAnnotation], in pdfView: PDFView) {
    for annotation in annotations {
      guard let page = annotation.page else { continue }
      let rect = pdfView.convert(annotation.bounds, from: page).insetBy(dx: -2, dy: -2)
      let overlay = FlashOverlayView(frame: rect)
      overlay.wantsLayer = true
      overlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
      overlay.layer?.cornerRadius = 3
      pdfView.addSubview(overlay)
      fadeOutAndRemove(overlay)
    }
  }

  /// 回链跳转后的整页闪烁提示（FR-5.3）：页面边框 + 浅底色，短暂显示后淡出
  static func flashPage(_ page: PDFPage, in pdfView: PDFView) {
    let rect = pdfView.convert(page.bounds(for: .mediaBox), from: page).insetBy(dx: 4, dy: 4)
    let overlay = FlashOverlayView(frame: rect)
    overlay.wantsLayer = true
    overlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
    overlay.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
    overlay.layer?.borderWidth = 2
    overlay.layer?.cornerRadius = 6
    pdfView.addSubview(overlay)
    fadeOutAndRemove(overlay)
  }

  private static func fadeOutAndRemove(_ overlay: NSView) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 1.0
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      overlay.animator().alphaValue = 0
    } completionHandler: {
      overlay.removeFromSuperview()
    }
  }
}

private final class FlashOverlayView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

#Preview {
  AnnotationListView()
    .environmentObject(PDFAnnotationStore())
    .environmentObject(PDFReaderStore())
    .frame(width: 266, height: 480)
}
