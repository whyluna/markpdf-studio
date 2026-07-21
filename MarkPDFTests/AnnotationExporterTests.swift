import PDFKit
import XCTest
@testable import MarkPDF

/// 标注导出 Markdown 格式化（FR-4.8）：行格式、按页排序、合并去重
final class AnnotationExporterTests: XCTestCase {
  /// 构造列表条目（page 为 1 起页码）
  private func makeItem(
    page: Int, excerpt: String, name: String = "", kind: AnnotationKind = .highlight
  ) -> AnnotationItem {
    let annotation = PDFAnnotation(bounds: .zero, forType: .highlight, withProperties: nil)
    return AnnotationItem(
      id: UUID().uuidString,
      annotations: [annotation],
      kind: kind,
      color: .yellow,
      pageIndex: page - 1,
      excerpt: excerpt,
      name: name
    )
  }

  // MARK: - 行格式

  func testLineExcerptOnly() {
    let line = AnnotationMarkdownExporter.line(for: makeItem(page: 3, excerpt: "核心论述")) { "a.pdf#page=\($0)" }
    XCTAssertEqual(line, "- [p.3](a.pdf#page=3) 核心论述")
  }

  func testLineWithName() {
    let line = AnnotationMarkdownExporter.line(for: makeItem(page: 3, excerpt: "摘录", name: "这是重点")) { "a.pdf#page=\($0)" }
    XCTAssertEqual(line, "- [p.3](a.pdf#page=3) 摘录 — 这是重点")
  }

  func testLineNameOnly() {
    let line = AnnotationMarkdownExporter.line(for: makeItem(page: 5, excerpt: "", name: "批注内容")) { "a.pdf#page=\($0)" }
    XCTAssertEqual(line, "- [p.5](a.pdf#page=5) 批注内容")
  }

  func testLineSkipsEmpty() {
    XCTAssertNil(AnnotationMarkdownExporter.line(for: makeItem(page: 1, excerpt: "")) { "a.pdf#page=\($0)" })
  }

  func testLineFlattensNameNewlines() {
    let line = AnnotationMarkdownExporter.line(for: makeItem(page: 2, excerpt: "", name: "第一行\n第二行")) { "a.pdf#page=\($0)" }
    XCTAssertEqual(line, "- [p.2](a.pdf#page=2) 第一行 第二行")
  }

  // MARK: - 排序

  func testLinesSortedByPage() {
    let items = [
      makeItem(page: 9, excerpt: "后"),
      makeItem(page: 1, excerpt: "先"),
      makeItem(page: 5, excerpt: "中"),
    ]
    let lines = AnnotationMarkdownExporter.lines(for: items) { "a.pdf#page=\($0)" }
    XCTAssertEqual(lines, ["- [p.1](a.pdf#page=1) 先", "- [p.5](a.pdf#page=5) 中", "- [p.9](a.pdf#page=9) 后"])
  }

  // MARK: - 合并去重

  func testMergeIntoNewFileHasTitle() {
    let (content, added) = AnnotationMarkdownExporter.mergedContent(
      existing: nil, pdfBaseName: "vllm", newLines: ["- [p.3](a.pdf#page=3) 摘录"])
    XCTAssertEqual(content, "# vllm 标注\n\n- [p.3](a.pdf#page=3) 摘录\n")
    XCTAssertEqual(added, 1)
  }

  func testMergeIntoEmptyExistingFileTreatedAsNew() {
    let (content, added) = AnnotationMarkdownExporter.mergedContent(
      existing: "  \n\n", pdfBaseName: "vllm", newLines: ["- [p.3](a.pdf#page=3) 摘录"])
    XCTAssertEqual(content, "# vllm 标注\n\n- [p.3](a.pdf#page=3) 摘录\n")
    XCTAssertEqual(added, 1)
  }

  func testMergeDedupsExistingLines() {
    let existing = "# vllm 标注\n\n- [p.3](a.pdf#page=3) 摘录\n"
    let (content, added) = AnnotationMarkdownExporter.mergedContent(
      existing: existing, pdfBaseName: "vllm", newLines: ["- [p.3](a.pdf#page=3) 摘录", "- [p.5](a.pdf#page=5) 新增"])
    XCTAssertEqual(content, "# vllm 标注\n\n- [p.3](a.pdf#page=3) 摘录\n\n- [p.5](a.pdf#page=5) 新增\n")
    XCTAssertEqual(added, 1)
  }

  func testMergeNoNewLinesReturnsZeroAndKeepsExisting() {
    let existing = "# vllm 标注\n\n- [p.3](a.pdf#page=3) 摘录\n"
    let (content, added) = AnnotationMarkdownExporter.mergedContent(
      existing: existing, pdfBaseName: "vllm", newLines: ["- [p.3](a.pdf#page=3) 摘录"])
    XCTAssertEqual(content, existing)
    XCTAssertEqual(added, 0)
  }

  func testMergeAppendsAfterSingleTrailingNewline() {
    let existing = "# 笔记\n"
    let (content, added) = AnnotationMarkdownExporter.mergedContent(
      existing: existing, pdfBaseName: "vllm", newLines: ["- [p.1](a.pdf#page=1) 摘录"])
    XCTAssertEqual(content, "# 笔记\n\n- [p.1](a.pdf#page=1) 摘录\n")
    XCTAssertEqual(added, 1)
  }

  func testMergeAppendsAfterMissingTrailingNewline() {
    let existing = "# 笔记"
    let (content, _) = AnnotationMarkdownExporter.mergedContent(
      existing: existing, pdfBaseName: "vllm", newLines: ["- [p.1](a.pdf#page=1) 摘录"])
    XCTAssertEqual(content, "# 笔记\n\n- [p.1](a.pdf#page=1) 摘录\n")
  }
}
