import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/ReplaceAllTests.cs: the same cases.

final class ReplaceAllTests: XCTestCase {
    private func open(_ contents: String...) throws -> PdfEditSession {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<contents.count).map { "\(10 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(contents.count) /MediaBox [0 0 600 800]>>")
        pdf.obj(5, EditKit.helvetica)
        pdf.obj(7, "<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /Identity-V /DescendantFonts [<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial " +
            "/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 600>>] /ToUnicode 8 0 R>>")
        pdf.stream(8, "", "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def /CMapType 2 def " +
            "1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfrange <0041> <005A> <0041> endbfrange endcmap end end")
        for i in 0..<contents.count {
            pdf.obj(10 + i, "<</Type /Page /Parent 2 0 R /Contents \(30 + i) 0 R /Resources <</Font <</F1 5 0 R /F3 7 0 R>>>>>>")
            pdf.stream(30 + i, "", contents[i])
        }
        return try PdfEditSession.open(pdf.finish())
    }

    private func page(_ session: PdfEditSession, _ index: Int) throws -> String {
        let document = try PdfDocument.open(session.current)
        return DotNetText.trim(TextPage.create(document, document.pages[index]).text)
    }

    func test_everyMatchOnEveryPageIsReplacedInOneUndoStep() throws {
        let session = try open(
            "BT /F1 12 Tf 50 700 Td (The colour of colour) Tj 0 -20 Td (Colour wheel) Tj ET",
            "BT /F1 12 Tf 50 700 Td (no match here) Tj ET",
            "BT /F1 12 Tf 50 700 Td [(a co) 10 (lour)] TJ ET")
        let report = try TextReplacer.replaceAll(session, "colour", "color")
        XCTAssertEqual(report.replaced, 4)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(report.pages, [0, 2])
        XCTAssertEqual(try page(session, 0), "The color of color\ncolor wheel")
        XCTAssertEqual(try page(session, 2), "a color")
        XCTAssertEqual(session.undoLabel, "Replace text")
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(try page(session, 0), "The colour of colour\nColour wheel")
        XCTAssertFalse(session.canUndo)
    }

    func test_theOptionsOfTheSearchApply() throws {
        let content = "BT /F1 12 Tf 50 700 Td (cat Cat concat) Tj ET"
        var session = try open(content)
        _ = try TextReplacer.replaceAll(session, "cat", "dog", TextSearchOptions(matchCase: true, wholeWord: true))
        XCTAssertEqual(try page(session, 0), "dog Cat concat")
        session = try open(content)
        _ = try TextReplacer.replaceAll(session, "cat", "dog")
        XCTAssertEqual(try page(session, 0), "dog dog condog")
    }

    func test_aRegularExpressionReplacementTakesGroups() throws {
        let session = try open("BT /F1 12 Tf 50 700 Td (12 apples and 7 apples) Tj ET")
        let report = try TextReplacer.replaceAll(session, "(\\d+) apples", "$1 pears", TextSearchOptions(regex: true))
        XCTAssertEqual(report.replaced, 2)
        XCTAssertEqual(try page(session, 0), "12 pears and 7 pears")
    }

    func test_whatCannotBeReplacedIsReportedAndLeftAlone() throws {
        let session = try open(
            "BT /F1 12 Tf 50 700 Td (a world here) Tj ET",
            "BT /F3 12 Tf 50 700 Td <0057004F0052004C0044> Tj ET",
            "BT /F1 12 Tf 50 700 Td (the wor) Tj 0 -14 Td (ld ends) Tj ET")
        let report = try TextReplacer.replaceAll(session, "world", "globe")
        XCTAssertEqual(report.replaced, 1)
        let failure = try assertSingle(report.failed)
        XCTAssertEqual(failure.page, 1)
        XCTAssertEqual(failure.reason, EditingText.vertical)
        XCTAssertEqual(try page(session, 0), "a globe here")
        XCTAssertEqual(try page(session, 1), "WORLD")
    }

    func test_lettersNoFontHasAreReportedPerMatch() throws {
        let session = try open("BT /F1 12 Tf 50 700 Td (one two two) Tj ET")
        var report = try TextReplacer.replaceAll(session, "two", "ğ")
        XCTAssertEqual(report.replaced, 0)
        XCTAssertEqual(report.failed.count, 2)
        for f in report.failed { XCTAssertEqual(f.reason, EditingText.noFont) }
        XCTAssertFalse(session.canUndo)
        report = try TextReplacer.replaceAll(session, "two", "ğ", fonts: EditArialSource())
        XCTAssertEqual(report.replaced, 2)
        XCTAssertEqual(try page(session, 0), "one ğ ğ")
        XCTAssertEqual(Set(report.substitutions.map { $0.characters }).count, 1)
    }

    func test_manyMatchesInOneRunKeepTheTextAround() throws {
        let session = try open("BT /F1 12 Tf 50 700 Td (aa bb aa bb aa bb aa) Tj ET")
        let report = try TextReplacer.replaceAll(session, "aa", "xyz")
        XCTAssertEqual(report.replaced, 4)
        XCTAssertEqual(try page(session, 0), "xyz bb xyz bb xyz bb xyz")
    }
}
