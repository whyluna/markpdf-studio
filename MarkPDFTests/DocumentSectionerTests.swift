import XCTest
@testable import MarkPDF

/// 结构切节 / 路由解析 / 工作区召回（FR-AI.2 v1.2 纯函数）
final class DocumentSectionerTests: XCTestCase {
  // MARK: - md 切节

  func testMarkdownSplitsByHeadings() {
    let markdown = """
      引言前文字

      # 方法
      方法内容

      ## 数据集
      数据集内容

      # 结论
      结论内容
      """
    let sections = DocumentSectioner.fromMarkdown(markdown)
    XCTAssertEqual(sections.map(\.title), ["开头", "方法", "数据集", "结论"])
    XCTAssertEqual(sections[1].anchor, "§方法")
    XCTAssertEqual(sections[3].text, "结论内容")
  }

  func testFencedHashNotTreatedAsHeading() {
    let markdown = """
      # 真标题
      ```
      # 注释不是标题
      ```
      正文
      """
    XCTAssertEqual(DocumentSectioner.fromMarkdown(markdown).count, 1)
  }

  func testNoHeadingsFallsBackToChunks() {
    let text = String(repeating: "字", count: DocumentSectioner.fallbackChunkChars + 100)
    let sections = DocumentSectioner.fromMarkdown(text)
    XCTAssertEqual(sections.count, 2)
    XCTAssertEqual(sections[0].text.count, DocumentSectioner.fallbackChunkChars)
  }

  // MARK: - 目录摘要与拼装

  func testOutlineDigestAndAssemble() {
    let sections = [
      DocumentSection(title: "方法", anchor: "§方法", text: "方法正文"),
      DocumentSection(title: "实验", anchor: "p.5-8", text: "实验正文"),
      DocumentSection(title: "结论", anchor: "§结论", text: "结论正文"),
    ]
    let digest = DocumentSectioner.outlineDigest(sections)
    XCTAssertTrue(digest.contains("0. [§方法] 方法 — 方法正文"))
    XCTAssertTrue(digest.contains("1. [p.5-8] 实验"))

    let assembled = DocumentSectioner.assemble(sections: sections, picked: [2, 0], budget: 10_000)
    XCTAssertTrue(assembled.hasPrefix("[§结论] 结论"), "按选中顺序拼装（最相关在前）")
    XCTAssertTrue(assembled.contains("[§方法] 方法"))
    XCTAssertFalse(assembled.contains("实验正文"), "未选中的节不进上下文")
  }

  func testAssembleRespectsBudget() {
    let sections = [
      DocumentSection(title: "A", anchor: "§A", text: String(repeating: "甲", count: 100)),
      DocumentSection(title: "B", anchor: "§B", text: String(repeating: "乙", count: 100)),
    ]
    let assembled = DocumentSectioner.assemble(sections: sections, picked: [0, 1], budget: 60)
    XCTAssertLessThanOrEqual(assembled.count, 60)
    XCTAssertFalse(assembled.contains("乙"), "预算耗尽即停")
  }

  // MARK: - 路由解析

  func testParsePickedNormalAndNoisy() {
    XCTAssertEqual(AISectionRouter.parsePicked("[2,0,5]", sectionCount: 6), [2, 0, 5])
    XCTAssertEqual(AISectionRouter.parsePicked("Sure! The answer is [1, 3].", sectionCount: 4), [1, 3])
    // 越界丢弃、重复去重
    XCTAssertEqual(AISectionRouter.parsePicked("[0, 9, 0, 1]", sectionCount: 3), [0, 1])
  }

  func testParsePickedGarbageReturnsNil() {
    XCTAssertNil(AISectionRouter.parsePicked("无法确定", sectionCount: 5))
    XCTAssertNil(AISectionRouter.parsePicked("[]", sectionCount: 5))
    XCTAssertNil(AISectionRouter.parsePicked("[99]", sectionCount: 5))
  }

  // MARK: - 工作区召回

  func testKeywordsTokenizesChineseAndEnglish() {
    let words = AIWorkspaceRetriever.keywords(from: "Transformer 的注意力机制是什么")
    XCTAssertTrue(words.contains("Transformer"))
    XCTAssertTrue(words.contains { $0.contains("注意") || $0.contains("机制") })
    XCTAssertFalse(words.contains("的"), "单字虚词不作检索词")
  }

  func testCandidateSectionsFindsAndExcludesCurrentDoc() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("RetrieverTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let noteA = dir.appendingPathComponent("attention.md")
    let noteB = dir.appendingPathComponent("current.md")
    try "# 原理\nattention mechanism 详解\n\n# 实现\n实现细节".write(to: noteA, atomically: true, encoding: .utf8)
    try "attention 在当前文档里".write(to: noteB, atomically: true, encoding: .utf8)

    let candidates = AIWorkspaceRetriever.candidateSections(
      question: "解释 attention 机制",
      files: [noteA, noteB],
      excluding: noteB
    )
    XCTAssertEqual(Set(candidates.map(\.file)), ["attention.md"], "当前文档被排除")
    XCTAssertEqual(candidates.map(\.section.title), ["原理", "实现"], "命中文件按标题树切节")

    // 目录摘要含文件名+锚点；拼装选节带全文并按份额截断
    let outline = AIWorkspaceRetriever.routingOutline(candidates)
    XCTAssertTrue(outline.contains("0. [attention.md §原理] 原理"))
    let hits = AIWorkspaceRetriever.assembleHits(candidates: candidates, picked: [1])
    XCTAssertEqual(hits.count, 1)
    XCTAssertEqual(hits.first?.anchor, "§实现")
    XCTAssertEqual(hits.first?.snippet, "实现细节")
  }

  // MARK: - 多词合并计分 + 切节缓存（v1.2 性能）

  func testMultiTermScoreCountsAllTerms() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ScoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = dir.appendingPathComponent("a.md")
    try "attention attention transformer".write(to: note, atomically: true, encoding: .utf8)

    XCTAssertEqual(FullTextSearch.multiTermScore(url: note, terms: ["attention", "transformer"]), 3)
    XCTAssertEqual(FullTextSearch.multiTermScore(url: note, terms: ["没有的词"]), 0)
    XCTAssertEqual(FullTextSearch.multiTermScore(url: note, terms: []), 0)
  }

  func testSectionCacheHitAndInvalidation() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("CacheTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = dir.appendingPathComponent("c.md")
    try "# 甲\n内容一".write(to: note, atomically: true, encoding: .utf8)

    let cache = DocumentSectionCache()
    var computeCount = 0
    let compute: () -> [DocumentSection]? = {
      computeCount += 1
      return (try? String(contentsOf: note, encoding: .utf8)).map { DocumentSectioner.fromMarkdown($0) }
    }

    XCTAssertEqual(cache.sections(for: note, compute: compute)?.first?.title, "甲")
    _ = cache.sections(for: note, compute: compute)
    XCTAssertEqual(computeCount, 1, "第二次命中缓存不重算")
    XCTAssertTrue(cache.isCached(note))

    // 文件修改（mtime/大小变）→ 失效重算
    try "# 乙\n内容改了改了".write(to: note, atomically: true, encoding: .utf8)
    XCTAssertFalse(cache.isCached(note))
    XCTAssertEqual(cache.sections(for: note, compute: compute)?.first?.title, "乙")
    XCTAssertEqual(computeCount, 2)
  }

  func testFallbackHitsTruncates() {
    let candidates = (0..<5).map {
      AIWorkspaceRetriever.Candidate(
        file: "f\($0).md",
        section: DocumentSection(title: "节", anchor: "§节", text: String(repeating: "字", count: 500))
      )
    }
    let hits = AIWorkspaceRetriever.fallbackHits(candidates: candidates)
    XCTAssertEqual(hits.count, 3)
    XCTAssertEqual(hits.first?.snippet.count, 300)
  }
}
