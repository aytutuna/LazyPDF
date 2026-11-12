import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextSearchTests.cs: the same cases. The document search is a stream in Swift,
// and its cancellation is the task's.

final class TextSearchTests: TextTestCase {
    private func find(_ page: TextPage, _ query: String, _ options: TextSearchOptions? = nil) throws -> [SearchMatch] {
        try TextSearch.find(page, query, options)
    }

    private func sample() throws -> TextPage {
        try text(line(100, 700, "The quick Brown fox") + line(100, 688, "jumps over the lazy dog") + line(100, 676, "The end"))
    }

    func test_plainSearchIgnoresCaseAndGivesQuads() throws {
        let hits = try find(try sample(), "the")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].text, "The")
        XCTAssertEqual(hits[0].range, TextRange(0, 3))
        XCTAssertEqual(hits[0].quads.count, 1)
        let quad = hits[0].quads[0]
        XCTAssertEqual(quad.bounds.left, 100, accuracy: 1e-6)
        XCTAssertEqual(quad.bounds.right, 115, accuracy: 1e-6)
        XCTAssertEqual(hits[0].page, 0)
    }

    func test_matchCaseTakesOnlyTheSameCase() throws {
        let page = try sample()
        XCTAssertEqual(try find(page, "The", TextSearchOptions(matchCase: true)).count, 2)
        XCTAssertEqual(try find(page, "Brown", TextSearchOptions(matchCase: true)).count, 1)
        XCTAssertTrue(try find(page, "brown", TextSearchOptions(matchCase: true)).isEmpty)
    }

    func test_wholeWordRefusesWordParts() throws {
        let page = try sample()
        XCTAssertEqual(try find(page, "the").count, 3)
        XCTAssertTrue(try find(page, "ov", TextSearchOptions(wholeWord: true)).isEmpty)
        XCTAssertEqual(try find(page, "over", TextSearchOptions(wholeWord: true)).count, 1)
        XCTAssertEqual(try find(page, "the", TextSearchOptions(wholeWord: true)).count, 3)
    }

    func test_aMatchCanRunOverALineBreak() throws {
        let hits = try find(try sample(), "fox jumps")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].quads.count, 2)
        XCTAssertEqual(hits[0].text, "fox\njumps")
    }

    func test_anyWhiteSpaceInTheQueryMatchesAnyGap() throws {
        let page = try text("BT /F1 10 Tf 100 700 Td [(a) -800 (b)] TJ ET")
        XCTAssertEqual(try find(page, "a   b").count, 1)
        XCTAssertEqual(try find(page, "a b").count, 1)
    }

    func test_aHyphenAtALineEndIsPartOfTheMatchOrNot() throws {
        let page = try text(line(100, 700, "some informa-") + line(100, 688, "tion and a well-") + line(100, 676, "known case"))
        let split = try find(page, "information")
        XCTAssertEqual(split.count, 1)
        XCTAssertEqual(split[0].quads.count, 2)
        XCTAssertEqual(split[0].text.replacingOccurrences(of: "\n", with: ""), "information")
        XCTAssertEqual(try find(page, "well-known").count, 1)
        XCTAssertEqual(try find(page, "informa-tion").count, 1)
    }

    func test_aSoftHyphenAtALineEndJoinsToo() throws {
        let page = try text(line(100, 700, #"some informa\001"#) + line(100, 688, "tion here"), "", (1, "\u{AD}"))
        XCTAssertEqual(try find(page, "information").count, 1)
    }

    func test_regexSearchWorksOnTheTextOfThePage() throws {
        let page = try sample()
        let hits = try find(page, #"\b[qj]\w+"#, TextSearchOptions(regex: true))
        XCTAssertEqual(hits.map { $0.text }, ["quick", "jumps"])
        XCTAssertEqual(try find(page, #"Brown\s+fox"#, TextSearchOptions(matchCase: true, regex: true)).count, 1)
        XCTAssertEqual(try find(page, #"fox\sjumps"#, TextSearchOptions(regex: true)).count, 1)
        XCTAssertTrue(try find(page, "x*", TextSearchOptions(wholeWord: true, regex: true)).isEmpty)
    }

    func test_aBadPatternThrowsArgumentException() throws {
        let page = try sample()
        XCTAssertThrowsError(try find(page, "(", TextSearchOptions(regex: true)))
    }

    func test_anEmptyQueryFindsNothing() throws {
        let page = try sample()
        XCTAssertTrue(try find(page, "").isEmpty)
        XCTAssertTrue(try find(page, "   ").isEmpty)
    }

    func test_foldingIgnoresDiacritics() throws {
        let page = try text(line(100, 700, #"caf\001 na\002ve r\003sum\001"#), "", (1, "\u{E9}"), (2, "\u{EF}"), (3, "\u{E9}"))
        XCTAssertTrue(try find(page, "cafe").isEmpty)
        let fold = TextSearchOptions(foldDiacritics: true)
        XCTAssertEqual(try find(page, "cafe", fold).count, 1)
        XCTAssertEqual(try find(page, "naive", fold).count, 1)
        XCTAssertEqual(try find(page, "r\u{E9}sum\u{E9}", fold).count + find(page, "resume", fold).count, 2)
        XCTAssertEqual(try find(page, "caf\u{E9}").count, 1)
    }

    func test_foldingMatchesLettersFromCombiningMarks() throws {
        let page = try text(line(100, 700, #"cafe\001"#), "", (1, "\u{301}"))
        XCTAssertEqual(try find(page, "cafe", TextSearchOptions(foldDiacritics: true)).count, 1)
    }

    func test_dottedAndDotlessIAreDifferentUntilFolded() throws {
        let page = try text(line(100, 700, #"\001stanbul \002\003\002k \004zmir"#), "", (1, "\u{130}"), (2, "\u{131}"), (3, "\u{15F}"), (4, "I"))
        XCTAssertEqual(try find(page, "\u{130}stanbul").count, 1)
        XCTAssertEqual(try find(page, "istanbul").count, 1)
        XCTAssertEqual(try find(page, "Istanbul").count, 1)
        XCTAssertEqual(try find(page, "\u{131}\u{15F}\u{131}k").count, 1)
        XCTAssertTrue(try find(page, "isik").isEmpty)
        XCTAssertEqual(try find(page, "izmir").count, 1)
        XCTAssertTrue(try find(page, "\u{131}zmir").isEmpty)

        let fold = TextSearchOptions(foldDiacritics: true)
        XCTAssertEqual(try find(page, "istanbul", fold).count, 1)
        XCTAssertEqual(try find(page, "\u{130}STANBUL", fold).count, 1)
        XCTAssertEqual(try find(page, "isik", fold).count, 1)
        XCTAssertEqual(try find(page, "ISIK", fold).count, 1)
        XCTAssertEqual(try find(page, "\u{131}zmir", fold).count, 1)
        XCTAssertEqual(try find(page, "izmir", fold).count, 1)
    }

    func test_matchesDoNotOverlap() throws {
        let page = try text(line(100, 700, "aaaa"))
        XCTAssertEqual(try find(page, "aa").count, 2)
    }

    func test_aSearchOverAnImpliedSpaceWorks() throws {
        let page = try text("BT /F1 10 Tf 100 700 Td [(one) -700 (two)] TJ ET")
        XCTAssertEqual(try find(page, "one two").count, 1)
    }

    func test_aDocumentSearchStreamsPageByPageAndCanBeCancelled() async throws {
        let doc = try threePages()
        var results: [SearchMatch] = []
        for try await match in try TextSearch.find(TextCache(doc), "page") { results.append(match) }
        XCTAssertEqual(results.map { $0.page }, [0, 1, 2])

        var some: [SearchMatch] = []
        for try await match in try TextSearch.find(TextCache(doc), "page", first: 1, last: 1) { some.append(match) }
        XCTAssertEqual(some.map { $0.page }, [1])

        let stream = try TextSearch.find(TextCache(doc), "page")
        let task = Task { () -> Bool in
            var iterator = stream.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first?.page, 0)
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await iterator.next()
                return false
            } catch is CancellationError {
                return true
            }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
    }

    func test_aRegexThatNeverEndsGivesNoHitsForThePage() throws {
        let page = try text(line(100, 700, String(repeating: "a", count: 40) + "!"))
        let hits = try find(page, "^(a+)+$", TextSearchOptions(regex: true))
        XCTAssertTrue(hits.isEmpty)
    }

    func test_aTimedOutPageIsReported() throws {
        let page = try text(line(100, 700, String(repeating: "a", count: 40) + "!"))
        let timeouts = SearchTimeouts()
        // Some ICU builds give up on this pattern in under a second, so the limit is made shorter than any of them takes.
        TextSearch.regexTimeout = 0.01
        defer { TextSearch.regexTimeout = 2 }
        XCTAssertTrue(try TextSearch.find(page, "^(a+)+$", TextSearchOptions(regex: true), timeouts: timeouts).isEmpty)
        XCTAssertEqual(timeouts.pages, [0])
        TextSearch.regexTimeout = 2
        let quiet = SearchTimeouts()
        XCTAssertEqual(try TextSearch.find(page, "a+!", TextSearchOptions(regex: true), timeouts: quiet).count, 1)
        XCTAssertTrue(quiet.pages.isEmpty)
    }

    private func threePages() throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 600 800]>>")
        for i in 0..<3 { pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(6 + i) 0 R /Resources <</Font <</F1 9 0 R>>>>>>") }
        for i in 0..<3 { pdf.stream(6 + i, "", line(100, 700, "on page number \(i)")) }
        font(pdf, 9)
        return try PdfDocument.open(pdf.finish())
    }
}
