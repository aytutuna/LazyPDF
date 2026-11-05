import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/ComparisonReportTests.cs: the same cases. The PdfPig lines (the report opened by a
// second reader and its pages counted) have no twin, and PdfPig's text of the summary page is the glyphs' own text, in the order
// shown. The C# font source reads arial.ttf, which has the letters of the file name; here the font has A, B, space, ğ, İ and
// ı, so the name is "AB ğİ BA".

final class ComparisonReportTests: CompareTestCase {
    private let date = DateTimeOffset(2026, 3, 4, 5, 6, 7)

    private func pages(_ topics: String...) -> [[String]] { topics.map { page($0) } }

    private func report(_ before: [[String]], _ after: [[String]], _ fonts: FontSource? = nil, oldName: String = "old.pdf",
                        newName: String = "new.pdf") throws -> (report: [UInt8], opened: PdfDocument, result: ComparisonResult) {
        let a = try doc(before)
        let b = try doc(after)
        let result = try PdfComparer.compare(a, b)
        let bytes = try ComparisonReport.write(b, result, oldName, newName, fonts, date)
        return (bytes, try PdfDocument.open(bytes), result)
    }

    private func summary(_ report: [UInt8]) throws -> String { try CompareKit.shown(report, 0) }

    private func marks(_ document: PdfDocument, _ page: Int) -> [PdfAnnotation] {
        PdfAnnotations.read(document, document.pages[page]).filter { $0.type == .highlight }
    }

    func test_reportHasSummaryInFrontAndHighlightsOnTheNewPages() throws {
        let before = [page("a"), page("b")]
        var after = [page("a"), page("b")]
        after[1][2] = "b line3 b3w1 b3w2 CHANGED b3w4 b3w5 b3w6 b3w7 b3w8"
        let (_, report, result) = try self.report(before, after)
        XCTAssertEqual(report.pages.count, 3)
        XCTAssertTrue(marks(report, 0).isEmpty)
        XCTAssertTrue(marks(report, 1).isEmpty)
        let mark = try single(marks(report, 2))
        XCTAssertEqual(mark.contents, "Was: b3w3")
        XCTAssertEqual(mark.color, [1, 0.85, 0.35])
        XCTAssertEqual(mark.title, "Lazy PDF")
        XCTAssertEqual(mark.created, date)
        let box = try single(mark.quads).bounds
        assertInRange(box.bottom, 690, 705)
        XCTAssertEqual(result.summary.changed, 1)
    }

    func test_addedRemovedAndChangedHaveTheirOwnColours() throws {
        let before = page("x", 6)
        var after = before
        after[0] = "x line1 ADDED x1w1 x1w2 x1w3 x1w4 x1w5 x1w6 x1w7 x1w8"
        after[2] = "x line3 x3w1 x3w2 x3w3 x3w4 x3w5 x3w6 x3w7"
        after[4] = "x line5 x5w1 x5w2 x5w3 REPLACED x5w5 x5w6 x5w7 x5w8"
        let (_, report, result) = try self.report([before], [after])
        XCTAssertEqual(result.summary.added, 1)
        XCTAssertEqual(result.summary.removed, 1)
        XCTAssertEqual(result.summary.changed, 1)
        let found = marks(report, 1)
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(try single(found, where: { $0.subject == "Added" }).color, [0.55, 0.85, 0.55])
        let removed = try single(found, where: { $0.subject == "Removed" })
        XCTAssertEqual(removed.color, [1, 0.55, 0.55])
        XCTAssertEqual(try single(found, where: { $0.subject == "Changed" }).color, [1, 0.85, 0.35])
        XCTAssertEqual(removed.contents, "Was: x3w8")
        // The mark of a removal is a sliver at the place where the text was.
        assertInRange(removed.rect.width, 3, 12)
    }

    func test_movedTextIsMarkedAsChangedWithItsOrigin() throws {
        let lines = page("m", 8)
        let moved = [lines[0], lines[1], lines[5], lines[2], lines[3], lines[4], lines[6], lines[7]]
        let (_, report, _) = try self.report([lines], [moved])
        let mark = try single(marks(report, 1))
        XCTAssertEqual(mark.subject, "Moved")
        XCTAssertEqual(mark.contents, CompareText.movedFrom(0))
    }

    func test_insertedPageGetsANoteAndRemovedPageIsListedInTheSummary() throws {
        let (bytes, report, _) = try self.report(pages("a", "b", "c"), pages("a", "x", "c"))
        XCTAssertTrue(try summary(bytes).contains("Page removed: 2"))
        let notes = PdfAnnotations.read(report, report.pages[2]).filter { $0.type == .text }
        XCTAssertEqual(try single(notes).contents, "Page added")
    }

    func test_summaryNamesTheFilesAndCounts() throws {
        var after = page("n", 6)
        after[1] = "n line2 n2w1 NEW n2w3 n2w4 n2w5 n2w6 n2w7 n2w8"
        let (bytes, _, _) = try self.report([page("n", 6)], [after], oldName: "first.pdf", newName: "second.pdf")
        let text = try summary(bytes)
        XCTAssertTrue(text.contains("Comparison"))
        XCTAssertTrue(text.contains("first.pdf"))
        XCTAssertTrue(text.contains("second.pdf"))
        XCTAssertTrue(text.contains("1 difference"))
        XCTAssertTrue(text.contains("Changed: 1"))
    }

    func test_identicalFilesGiveASummaryWithoutMarks() throws {
        let (bytes, report, result) = try self.report(pages("a", "b"), pages("a", "b"))
        XCTAssertTrue(result.isIdentical)
        XCTAssertEqual(report.pages.count, 3)
        XCTAssertTrue(try summary(bytes).contains("No differences found."))
        for p in 1...2 { XCTAssertTrue(marks(report, p).isEmpty) }
    }

    func test_reportReopensInPdfPigWithEveryPage() throws {
        let (bytes, report, _) = try self.report(pages("a", "b", "c"), pages("c", "a", "q", "b"))
        XCTAssertEqual(report.pages.count, 5)
        XCTAssertTrue(try CompareKit.shown(bytes, 2).contains("a line1"))
    }

    func test_theDocumentPassedInIsNotChanged() throws {
        let before = try doc(pages("a"))
        let file = TestPdf.text(bytes(pages("a").map { $0.map { CompareLine($0) } })).replacingOccurrences(of: "a line1", with: "z line1")
        let changed = try open(TestPdf.latin(file))
        let result = try PdfComparer.compare(before, changed)
        XCTAssertFalse(result.isIdentical)
        _ = try ComparisonReport.write(changed, result, "a", "b")
        XCTAssertEqual(changed.pages.count, 1)
        XCTAssertTrue(PdfAnnotations.read(changed, changed.pages[0]).isEmpty)
    }

    func test_namesOutsideLatin1PrintAsQuestionMarksWithoutAFontAndInFullWithOne() throws {
        let name = "AB ğİ BA"
        let plain = try self.report(pages("a"), pages("a"), nil, oldName: name, newName: "yeni.pdf")
        XCTAssertTrue(try summary(plain.report).contains("AB ?? BA"))
        let embedded = try self.report(pages("a"), pages("a"), try CompareArial(), oldName: name, newName: "yeni.pdf")
        XCTAssertTrue(try summary(embedded.report).contains(name))
    }

    func test_longSummariesRunOverSeveralPages() throws {
        let a = try doc(pages("a"))
        var metadata = DocumentMetadata.read(a)
        var custom = OrderedStrings()
        for i in 0..<120 { custom["Key\(i)"] = "value \(i)" }
        metadata.custom = custom
        try metadata.write(a)
        let before = try open(a.saveRewrite())
        let after = try doc(pages("a"))
        let result = try PdfComparer.compare(before, after)
        XCTAssertEqual(result.summary.document, 120)
        let report = try PdfDocument.open(try ComparisonReport.write(after, result, "a", "b"))
        XCTAssertTrue(report.pages.count >= 3, "\(report.pages.count)")
    }

    func test_textOutputListsChangesByPage() throws {
        let before = [page("a"), page("b")]
        var after = [page("a"), page("b")]
        after[1][1] = "b line2 b2w1 b2w2 b2w3 CHANGED b2w5 b2w6 b2w7 b2w8"
        let x = try doc(before)
        let y = try doc(after)
        let text = ComparisonReport.toText(try PdfComparer.compare(x, y), "old.pdf", "new.pdf")
        XCTAssertTrue(text.hasPrefix("Comparison\nold.pdf / new.pdf\n"))
        XCTAssertTrue(text.contains("1 difference: Added 0, Removed 0, Changed 1, Moved 0"))
        XCTAssertTrue(text.contains("Pages 2\n  Changed text: b2w4 -> CHANGED"))
    }

    func test_textOutputForIdenticalFilesSaysSo() throws {
        let x = try doc(pages("a"))
        XCTAssertTrue(ComparisonReport.toText(try PdfComparer.compare(x, x), "a", "b").hasSuffix("No differences found.\n"))
    }

    func test_textOutputIncludesDocumentDifferences() throws {
        let a = try doc(pages("a"))
        var metadata = DocumentMetadata.read(a)
        metadata.title = "One"
        try metadata.write(a)
        let x = try open(a.saveRewrite())
        let y = try doc(pages("a"))
        let text = ComparisonReport.toText(try PdfComparer.compare(x, y), "a", "b")
        XCTAssertTrue(text.contains("Document\n  Removed document (Title): One"))
    }

    func test_removalFromAPageWithAnotherBoxIsMarkedAtTheSamePlaceOfTheDisplayedPage() throws {
        let a = try open(bytes([[CompareLine("alpha beta gamma")]]))
        let b = try open(bytes([[]], pageKeys: "/MediaBox [100 100 406 496]"))
        let result = try PdfComparer.compare(a, b)
        let report = try PdfDocument.open(try ComparisonReport.write(a, b, result, "old.pdf", "new.pdf", nil, date))
        // The words stood at x 72 and y about 740 of 612 by 792; the new page is half that size with its origin at 100.
        let box = try single(try single(marks(report, 1)).quads).bounds
        assertInRange(box.left, 134, 138)
        assertInRange(box.bottom, 462, 476)
    }
}
