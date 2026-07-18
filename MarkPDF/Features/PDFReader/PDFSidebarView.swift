import PDFKit
import SwiftUI

/// PDF 侧栏（FR-3.3/4.5）：缩略图 / 书签（文档大纲 + 用户书签）/ 标注列表。
/// 分段控件对齐设计稿 `.seg`。
struct PDFSidebarView: View {
  let url: URL
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @EnvironmentObject private var bookmarksStore: PDFBookmarksStore
  @EnvironmentObject private var annotationStore: PDFAnnotationStore
  @State private var segment = Segment.thumbnails

  private enum Segment: String, CaseIterable, Identifiable {
    case thumbnails = "缩略图"
    case bookmarks = "书签"
    case annotations = "标注"
    var id: String { rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("面板", selection: $segment) {
        ForEach(Segment.allCases) { segment in
          // 标注段显示计数（对齐设计稿 "标注 5"）
          if segment == .annotations {
            Text("标注 \(annotationStore.annotationItems().count)").tag(segment)
          } else {
            Text(segment.rawValue).tag(segment)
          }
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(10)
      Divider()
      switch segment {
      case .thumbnails:
        PDFThumbnailRepresentable(pdfView: pdfStore.pdfView)
      case .bookmarks:
        bookmarkContent
      case .annotations:
        AnnotationListView()
      }
    }
  }

  // MARK: - 书签（文档大纲 + 用户书签）

  private var bookmarkContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if let outlineRoot = pdfStore.pdfView?.document?.outlineRoot, outlineRoot.numberOfChildren > 0 {
          sectionTitle("文档大纲")
          ForEach(0..<outlineRoot.numberOfChildren, id: \.self) { index in
            if let child = outlineRoot.child(at: index) {
              PDFOutlineRow(outline: child) { destination in
                pdfStore.go(to: destination)
              }
            }
          }
        }
        sectionTitle("我的书签")
        Button {
          bookmarksStore.toggle(page: pdfStore.currentPage, for: url)
        } label: {
          Label(
            bookmarksStore.contains(page: pdfStore.currentPage, for: url) ? "移除当前页书签" : "书签当前页",
            systemImage: bookmarksStore.contains(page: pdfStore.currentPage, for: url) ? "bookmark.fill" : "bookmark"
          )
          .font(.callout)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        let pages = bookmarksStore.pages(for: url)
        if pages.isEmpty {
          Text("暂无书签")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else {
          ForEach(pages, id: \.self) { page in
            BookmarkRow(page: page) {
              pdfStore.goTo(page: page)
            } onDelete: {
              bookmarksStore.remove(page: page, for: url)
            }
          }
        }
      }
      .padding(8)
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 6)
      .padding(.top, 6)
      .padding(.bottom, 4)
  }
}

// MARK: - 文档大纲行（递归）

private struct PDFOutlineRow: View {
  let outline: PDFOutline
  let onJump: (PDFDestination) -> Void
  @State private var isHovered = false

  var body: some View {
    Button {
      if let destination = outline.destination {
        onJump(destination)
      }
    } label: {
      Text(outline.label ?? "未命名")
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    if outline.numberOfChildren > 0 {
      ForEach(0..<outline.numberOfChildren, id: \.self) { index in
        if let child = outline.child(at: index) {
          PDFOutlineRow(outline: child, onJump: onJump)
            .padding(.leading, 14)
        }
      }
    }
  }
}

// MARK: - 用户书签行

private struct BookmarkRow: View {
  let page: Int
  let onJump: () -> Void
  let onDelete: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack {
      Button(action: onJump) {
        HStack {
          Image(systemName: "bookmark.fill")
            .foregroundStyle(Color.accentColor)
          Text("第 \(page) 页")
            .font(.system(size: 13))
          Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isHovered {
        Button(action: onDelete) {
          Image(systemName: "xmark")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
      }
    }
    .background(isHovered ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .onHover { isHovered = $0 }
  }
}

// MARK: - 缩略图（PDFKit 原生）

/// PDFKit 缩略图视图：直连当前 PDFView，页码跟踪与点击跳转由系统完成
private struct PDFThumbnailRepresentable: NSViewRepresentable {
  weak var pdfView: PDFView?

  func makeNSView(context: Context) -> PDFThumbnailView {
    let view = PDFThumbnailView()
    view.pdfView = pdfView
    view.thumbnailSize = NSSize(width: 120, height: 160)
    return view
  }

  func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
    if nsView.pdfView !== pdfView {
      nsView.pdfView = pdfView
    }
  }
}

#Preview {
  PDFSidebarView(url: URL(fileURLWithPath: "/tmp/demo.pdf"))
    .environmentObject(PDFReaderStore())
    .environmentObject(PDFBookmarksStore())
    .environmentObject(PDFAnnotationStore())
    .frame(width: 266, height: 480)
}
