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
    case thumbnails
    case bookmarks
    case annotations
    case references
    var id: String { rawValue }

    var title: String {
      switch self {
      case .thumbnails: String(localized: "缩略图")
      case .bookmarks: String(localized: "书签")
      case .annotations: String(localized: "标注")
      case .references: String(localized: "引用")
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("面板", selection: $segment) {
        ForEach(Segment.allCases) { segment in
          // 标注段显示计数（对齐设计稿 "标注 5"；读 Store 缓存，不在 body 重扫文档）
          if segment == .annotations {
            Text("标注 \(annotationStore.annotationItemsSnapshot.count)").tag(segment)
          } else {
            Text(segment.title).tag(segment)
          }
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(10)
      Divider()
      switch segment {
      case .thumbnails:
        PDFThumbnailListView()
      case .bookmarks:
        bookmarkContent
      case .annotations:
        AnnotationListView()
      case .references:
        // 反向链接（FR-5.4）：当前 PDF 被哪些 md 引用
        BacklinksPanelView(target: url)
      }
    }
  }

  // MARK: - 书签（文档大纲 + 用户书签）

  private var bookmarkContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if let outlineRoot = pdfStore.pdfView?.document?.outlineRoot, outlineRoot.numberOfChildren > 0 {
          sectionTitle(String(localized: "文档大纲"))
          ForEach(0..<outlineRoot.numberOfChildren, id: \.self) { index in
            if let child = outlineRoot.child(at: index) {
              PDFOutlineRow(outline: child) { destination in
                pdfStore.go(to: destination)
              }
            }
          }
        }
        sectionTitle(String(localized: "我的书签"))
        Button {
          // 加载窗口期（异步解析未完成）currentPage 为 0：0 页书签永远跳不到
          //（goTo 有 page>=1 防护），不得产生死书签（Bug 修复 4）
          guard Self.isBookmarkablePage(pdfStore.currentPage) else { return }
          bookmarksStore.toggle(page: pdfStore.currentPage, for: url)
        } label: {
          Label(
            bookmarksStore.contains(page: pdfStore.currentPage, for: url) ? String(localized: "移除当前页书签") : String(localized: "书签当前页"),
            systemImage: bookmarksStore.contains(page: pdfStore.currentPage, for: url) ? "bookmark.fill" : "bookmark"
          )
          .font(.callout)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(!Self.isBookmarkablePage(pdfStore.currentPage))
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

  /// 可加书签的页码判定（Bug 修复 4）：异步加载完成前 currentPage == 0，
  /// 0 页书签永远跳不到（goTo 有 page>=1 防护）
  static func isBookmarkablePage(_ page: Int) -> Bool {
    page >= 1
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

// MARK: - 缩略图（自绘列表）

/// 自绘缩略图列表：原生 PDFThumbnailView 依赖 `currentPage`/`PDFViewPageChanged`，
/// 二者在连续滚动中都不更新（实测日志确认），观感是「滚动停稳一秒后缩略图才跳」。
/// 自绘列表由 Store 的 currentPage（滚动实时跟页直写）驱动：实时高亮 + 滚到当前页
private struct PDFThumbnailListView: View {
  @EnvironmentObject private var pdfStore: PDFReaderStore
  @StateObject private var cache = ThumbnailCache()

  private var document: PDFDocument? { pdfStore.pdfView?.document }
  /// 文档标识（换文档后缓存键与单元任务随之失效）：
  /// 用文档 URL 而非 ObjectIdentifier——后者地址复用即串档显示旧文档缩略图
  private var docKey: String {
    document?.documentURL?.path ?? "none"
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 12) {
          if let document, pdfStore.pageCount > 0 {
            ForEach(1...pdfStore.pageCount, id: \.self) { page in
              ThumbnailCell(
                pageNumber: page,
                isCurrent: page == pdfStore.currentPage,
                taskKey: "\(docKey)-\(page)",
                loadImage: { await cache.image(pageIndex: page - 1, docKey: docKey, in: document) },
                onTap: { pdfStore.goTo(page: page) }
              )
              .id(page)
            }
          }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
      }
      .onAppear {
        proxy.scrollTo(pdfStore.currentPage, anchor: .center)
      }
      .onChange(of: pdfStore.currentPage) { page in
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo(page, anchor: .center)
        }
      }
    }
  }
}

/// 单页缩略图（懒加载 + 当前页高亮）
private struct ThumbnailCell: View {
  let pageNumber: Int
  let isCurrent: Bool
  /// 图片加载任务标识（文档 + 页码；换文档后触发重载）
  let taskKey: String
  let loadImage: () async -> NSImage?
  let onTap: () -> Void
  @State private var image: NSImage?

  var body: some View {
    VStack(spacing: 4) {
      Group {
        if let image {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
        } else {
          Rectangle()
            .fill(Color.primary.opacity(0.04))
            .aspectRatio(0.72, contentMode: .fit)
        }
      }
      .frame(width: 116)
      .background(Color.white)
      .overlay(
        RoundedRectangle(cornerRadius: 3)
          .stroke(
            isCurrent ? Color.accentColor : Color.primary.opacity(0.15),
            lineWidth: isCurrent ? 2.5 : 1
          )
      )
      Text("\(pageNumber)")
        .font(.caption)
        .fontWeight(isCurrent ? .semibold : .regular)
        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    .task(id: taskKey) {
      image = await loadImage()
    }
  }
}

/// 缩略图缓存：后台生成（237 页级文档不能在主线程逐页渲染），按文档+页码缓存。
/// 容量 FIFO 上限 + 换文档清空：237 页滚一遍 ~250MB 位图不再无界驻留
@MainActor
private final class ThumbnailCache: ObservableObject {
  private var images: [String: NSImage] = [:]
  private var order: [String] = []
  /// 缓存页数上限（约 80 页 × ~1MB）
  private let limit = 80
  private var currentDocKey = ""

  func image(pageIndex: Int, docKey: String, in document: PDFDocument) async -> NSImage? {
    // 换文档清空：旧文档位图不驻留
    if docKey != currentDocKey {
      images.removeAll()
      order.removeAll()
      currentDocKey = docKey
    }
    let key = "\(docKey)-\(pageIndex)"
    if let hit = images[key] { return hit }
    guard let page = document.page(at: pageIndex) else { return nil }
    // 2x 尺寸供 Retina 显示（展示宽 116pt）
    let image = await Task.detached(priority: .utility) {
      page.thumbnail(of: NSSize(width: 232, height: 320), for: .cropBox)
    }.value
    images[key] = image
    order.append(key)
    if order.count > limit, let evicted = order.first {
      order.removeFirst()
      images.removeValue(forKey: evicted)
    }
    return image
  }
}

#Preview {
  PDFSidebarView(url: URL(fileURLWithPath: "/tmp/demo.pdf"))
    .environmentObject(PDFReaderStore())
    .environmentObject(PDFBookmarksStore())
    .environmentObject(PDFAnnotationStore())
    .frame(width: 266, height: 480)
}
