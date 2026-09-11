import PDFKit
import SwiftUI
import XCTest
@testable import MarkPDF

@MainActor
final class PDFOutlineIndexTests: XCTestCase {
  func testLinkedContentsDeduplicatesPageNumbersAndKeepsHierarchyAndDestinations() throws {
    let doc = try fixture(duplicateNumbers: true)
    let result = PDFOutlineIndex.build(document: doc)
    XCTAssertEqual(result.source, .linkedContents)
    XCTAssertEqual(result.entries.map(\.title), ["Chapter One", "Section One", "Detail", "Chapter Two"])
    XCTAssertEqual(result.entries.map(\.level), [0, 1, 2, 0])
    XCTAssertEqual(result.entries.map(\.page), [3, 3, 4, 5])
    for (index, entry) in result.entries.enumerated() {
      let target = try XCTUnwrap(entry.target)
      let destination = try XCTUnwrap(target.destination(in: doc))
      XCTAssertTrue(destination.page === doc.page(at: target.pageIndex))
      XCTAssertEqual(destination.point, NSPoint(x: 55, y: 700 - CGFloat(index) * 30))
      XCTAssertEqual(destination.zoom, kPDFDestinationUnspecifiedValue)
    }
    XCTAssertNil(doc.outlineRoot, "提取目录不写回原 PDF")
  }

  func testNumberOnlyLinksRecoverTitleFromSameLine() throws {
    let doc = try fixture(numberOnly: true)
    let result = PDFOutlineIndex.build(document: doc)
    XCTAssertEqual(result.entries.count, 4)
    XCTAssertEqual(result.entries.map(\.title), ["Chapter One", "Section One", "Detail", "Chapter Two"])
    XCTAssertEqual(result.entries.map(\.level), [0, 1, 2, 0])
  }

  func testEmbeddedOutlineTakesPrecedenceAndSupportsActionOnlyDestination() throws {
    let doc = try fixture()
    let root = PDFOutline()
    let chapter = PDFOutline()
    chapter.label = "Native chapter"
    let child = PDFOutline()
    child.label = "Native child"
    child.action = PDFActionGoTo(destination: PDFDestination(page: doc.page(at: 4)!, at: NSPoint(x: 10, y: 600)))
    chapter.insertChild(child, at: 0)
    root.insertChild(chapter, at: 0)
    doc.outlineRoot = root
    let index = PDFOutlineIndex.build(document: doc)
    XCTAssertEqual(index.source, .embedded)
    XCTAssertEqual(index.entries.map(\.title), ["Native chapter", "Native child"])
    XCTAssertEqual(index.entries.map(\.level), [0, 1])
    XCTAssertNil(index.entries[0].target)
    XCTAssertEqual(index.entries[1].page, 5)
  }

  func testContentsContinuesAcrossPagesWithoutRepeatingHeading() throws {
    let doc = try fixture(continuation: true)
    let index = PDFOutlineIndex.build(document: doc)
    XCTAssertEqual(index.entries.count, 5)
    XCTAssertEqual(index.entries.last?.title, "Continuation")
    XCTAssertEqual(index.entries.last?.level, 1)
  }

  func testOrdinaryBodyReferencesAndWebsiteAreNotAnOutline() throws {
    let doc = try fixture(heading: "References", leaders: false)
    XCTAssertEqual(PDFOutlineIndex.build(document: doc), .empty)
  }

  func testStrongLeaderRowsWithoutContentsHeadingAreRecognized() throws {
    let doc = try fixture(heading: "")
    XCTAssertEqual(PDFOutlineIndex.build(document: doc).entries.count, 4)
  }

  func testForeignAndUnresolvableDestinationsAreIgnored() throws {
    let doc = try fixture()
    let page = try XCTUnwrap(doc.page(at: 0))
    let foreignDoc = try fixture()
    for a in page.annotations where a.type == "Link" {
      a.action = nil
      a.destination = PDFDestination(page: foreignDoc.page(at: 0)!, at: .zero)
    }
    XCTAssertEqual(PDFOutlineIndex.build(document: doc), .empty)
  }

  func testReadOnlyRoundTripAndScanLimit() throws {
    let doc = try fixture(duplicateNumbers: true)
    let data = try XCTUnwrap(doc.dataRepresentation())
    let reloaded = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertEqual(PDFOutlineIndex.build(document: reloaded).entries.count, 4)
    XCTAssertNil(reloaded.outlineRoot)
    // 目录移至扫描界限之后不会扫描整本书。
    let toc = try XCTUnwrap(doc.page(at: 0))
    doc.removePage(at: 0)
    for _ in 0..<PDFOutlineIndex.scanPageLimit { doc.insert(PDFPage(), at: 0) }
    doc.insert(toc, at: PDFOutlineIndex.scanPageLimit)
    XCTAssertEqual(PDFOutlineIndex.build(document: doc), .empty)
  }

  func testCancellationDoesNotReadLinkedContents() throws {
    XCTAssertEqual(PDFOutlineIndex.build(document: try fixture(), isCancelled: { true }), .empty)
  }

  func testTitleCleaningKeepsNumbersInTitlesAndRemovesLeaders() {
    XCTAssertEqual(PDFOutlineIndex.cleanedTitle("第一节 C 语言 ····· ····· 5"), "第一节 C 语言")
    XCTAssertEqual(PDFOutlineIndex.cleanedTitle("3.2 HTTP/2 ... ... 21"), "3.2 HTTP/2")
    XCTAssertEqual(PDFOutlineIndex.cleanedTitle("Chapter 2"), "Chapter 2")
    XCTAssertEqual(PDFOutlineIndex.cleanedTitle("Title… … …iv"), "Title")
    XCTAssertEqual(PDFOutlineIndex.cleanedTitle(".19"), "")
  }

  func testLoadedIndexPublishesAndFollowsFocusedPDFWithoutURLCache() throws {
    let docA = try fixture()
    let docB = try fixture(heading: "References", leaders: false)
    let viewA = ZoomablePDFView()
    let viewB = ZoomablePDFView()
    let store = PDFReaderStore()
    store.pdfView = viewA
    XCTAssertNil(store.outlineIndex)
    viewA.document = docA
    viewA.outlineIndex = PDFOutlineIndex.build(document: docA)
    store.refreshOutlineIndex()
    XCTAssertEqual(store.outlineIndex?.entries.count, 4)
    viewB.document = docB
    viewB.outlineIndex = PDFOutlineIndex.build(document: docB)
    store.pdfView = viewB
    XCTAssertEqual(store.outlineIndex, .empty)
    store.pdfView = viewA
    XCTAssertEqual(store.outlineIndex?.entries.count, 4)
    store.resetForDocumentSwitch()
    XCTAssertNil(store.outlineIndex)
  }

  func testSidebarUsesExtractedDestinationsInHiddenWindow() throws {
    let document = try fixture(duplicateNumbers: true)
    let pdf = ZoomablePDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
    pdf.document = document
    pdf.outlineIndex = PDFOutlineIndex.build(document: document)
    let reader = PDFReaderStore()
    reader.pdfView = pdf
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "PDFOutlineIndexTests"))
    defer { removeTestDefaultsSuite("PDFOutlineIndexTests", using: defaults) }
    let view = PDFSidebarView(url: URL(fileURLWithPath: "/tmp/outline-fixture.pdf"))
      .environmentObject(reader)
      .environmentObject(PDFBookmarksStore())
      .environmentObject(PDFAnnotationStore(defaults: defaults))
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 800),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 800))
    window.contentView = root
    root.addSubview(pdf)
    hosting.frame = NSRect(x: 600, y: 0, width: 340, height: 800)
    root.addSubview(hosting)
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    let last = try XCTUnwrap(reader.outlineIndex?.entries.last)
    reader.go(to: last)
    XCTAssertTrue(pdf.currentPage === document.page(at: 4))
    XCTAssertFalse(window.isVisible)
  }

  private func fixture(duplicateNumbers: Bool = false, numberOnly: Bool = false,
    heading: String = "Contents", leaders: Bool = true, continuation: Bool = false) throws -> PDFDocument {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 800)
    let consumer = try XCTUnwrap(CGDataConsumer(data: data))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    let titles = ["Chapter One", "Section One", "Detail", "Chapter Two"]
    let indents: [CGFloat] = [60, 80, 100, 60]
    for i in 0..<5 {
      context.beginPDFPage(nil)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
      if i == 0 {
        (heading as NSString).draw(at: NSPoint(x: 220, y: 750), withAttributes: attributes)
        for (n, title) in titles.enumerated() {
          ((title + (leaders ? " ..................." : "")) as NSString).draw(
            at: NSPoint(x: indents[n], y: 690 - CGFloat(n) * 30), withAttributes: attributes)
          ("\(n + 1)" as NSString).draw(at: NSPoint(x: 500, y: 690 - CGFloat(n) * 30), withAttributes: attributes)
        }
      } else if i == 1 && continuation {
        ("Continuation ................... 5" as NSString).draw(at: NSPoint(x: 80, y: 690), withAttributes: attributes)
      } else {
        ("Body page \(i)" as NSString).draw(at: NSPoint(x: 60, y: 690), withAttributes: attributes)
      }
      NSGraphicsContext.restoreGraphicsState()
      context.endPDFPage()
    }
    context.closePDF()
    let doc = try XCTUnwrap(PDFDocument(data: data as Data))
    let targets = [2, 2, 3, 4]
    for n in 0..<4 {
      func addLink(_ rect: CGRect, actionOnly: Bool) {
        let link = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
        let destination = PDFDestination(page: doc.page(at: targets[n])!, at: NSPoint(x: 55, y: 700 - CGFloat(n) * 30))
        if actionOnly { link.action = PDFActionGoTo(destination: destination) }
        else { link.destination = destination }
        doc.page(at: 0)!.addAnnotation(link)
      }
      if !numberOnly {
        addLink(CGRect(x: indents[n], y: 687 - CGFloat(n) * 30, width: 430 - indents[n], height: 21), actionOnly: n % 2 == 0)
      }
      if numberOnly || duplicateNumbers {
        addLink(CGRect(x: 498, y: 687 - CGFloat(n) * 30, width: 16, height: 21), actionOnly: true)
      }
    }
    let website = PDFAnnotation(bounds: CGRect(x: 30, y: 20, width: 200, height: 18), forType: .link, withProperties: nil)
    website.url = URL(string: "https://example.com")
    doc.page(at: 0)!.addAnnotation(website)
    if continuation {
      let link = PDFAnnotation(bounds: CGRect(x: 80, y: 687, width: 350, height: 21), forType: .link, withProperties: nil)
      link.destination = PDFDestination(page: doc.page(at: 4)!, at: NSPoint(x: 55, y: 550))
      doc.page(at: 1)!.addAnnotation(link)
    }
    return doc
  }
}
