import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextExportTests.cs: the same cases. The cancellation is the task's.

final class TextExportTests: TextTestCase {
    private func pages(_ count: Int, _ content: (Int) -> String) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<count).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 600 800]>>")
        for i in 0..<count {
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + count + i) 0 R /Resources <</Font <</F1 \(3 + 2 * count) 0 R>>>>>>")
        }
        for i in 0..<count { pdf.stream(3 + count + i, "", content(i)) }
        font(pdf, 3 + 2 * count)
        return try PdfDocument.open(pdf.finish())
    }

    func test_aPageExportsAsPlainText() throws {
        let page = try text(line(50, 700, "Title") + line(50, 650, "first line") + line(50, 638, "second line"))
        XCTAssertEqual(TextExport.page(page), "Title\n\nfirst line\nsecond line")
    }

    func test_hyphensAtLineEndsAreJoinedOnRequest() throws {
        let page = try text(line(50, 700, "a long informa-") + line(50, 688, "tion and well-") + line(50, 676, "Known text"))
        XCTAssertEqual(TextExport.page(page), "a long informa-\ntion and well-\nKnown text")
        XCTAssertEqual(TextExport.page(page, joinHyphens: true), "a long information and well-Known text")
    }

    func test_aRangeOfPagesIsSeparatedByFormFeeds() throws {
        let document = try pages(3) { self.line(50, 700, "page \($0 + 1)") }
        let cache = TextCache(document)
        XCTAssertEqual(try TextExport.range(cache, 0, 2), "page 1\u{0C}page 2\u{0C}page 3\u{0C}")
        XCTAssertEqual(try TextExport.range(cache, 1, 1), "page 2\u{0C}")
        XCTAssertEqual(try TextExport.range(cache, 2, 99), "page 3\u{0C}")
        XCTAssertEqual(try TextExport.range(cache, 5, 7), "")
    }

    func test_exportCanBeCancelled() async throws {
        let cache = TextCache(try pages(2) { _ in self.line(50, 700, "x") })
        let task = Task { () -> String in
            while !Task.isCancelled { await Task.yield() }
            return try TextExport.range(cache, 0, 1)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_theCacheKeepsPagesUntilTheCapIsHit() throws {
        let document = try pages(4) { _ in self.line(50, 700, "twelve chars") }
        let cache = TextCache(document, maxChars: 30)
        let first = cache.get(0)
        assertSame(first, cache.get(0))
        _ = cache.get(1)
        assertSame(first, cache.get(0))
        _ = cache.get(2)
        _ = cache.get(3)
        XCTAssertFalse(first === cache.get(0))
        XCTAssertEqual(cache.pageCount, 4)
    }

    func test_anOversizedPageIsStillReturned() throws {
        let cache = TextCache(try pages(1) { _ in self.line(50, 700, "more than five chars") }, maxChars: 5)
        XCTAssertEqual(cache.get(0).text, "more than five chars")
    }

    func test_clearingForgetsThePages() throws {
        let cache = TextCache(try pages(1) { _ in self.line(50, 700, "x") })
        let page = cache.get(0)
        cache.clear()
        XCTAssertFalse(page === cache.get(0))
    }

    func test_pagesAreNumberedByIndex() throws {
        let cache = TextCache(try pages(3) { _ in self.line(50, 700, "x") })
        XCTAssertEqual(cache.get(2).pageIndex, 2)
    }
}
