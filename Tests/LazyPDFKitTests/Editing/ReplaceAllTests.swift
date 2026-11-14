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
            pdf.obj(10 + i, "<</Type /Page /Parent 2 0 R /Contents \(30 + i) 0 R /Resources <</Font <</F1 5 0 R /F3 7 0 R>> /Properties <</MC0 <</MCID 4 /Lang (en) /ActualText (hello world)>>>>>>>>")
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

    private final class MarkedCollector: ContentVisitor {
        var marked: [MarkedContent] = []

        override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) { self.marked.append(marked) }
    }

    private func hello(_ open: String) -> String { "BT /F1 12 Tf 50 700 Td \(open) BDC (hello world) Tj EMC ET" }

    private func count(_ text: String, _ part: String) -> Int { text.components(separatedBy: part).count - 1 }

    func test_aHitInsideReplacementTextKeepsTheRestOfIt() throws {
        let session = try open(hello("/Span <</ActualText (hello world)>>"))
        let report = try TextReplacer.replaceAll(session, "world", "globe")
        XCTAssertEqual(report.replaced, 1)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(try page(session, 0), "hello globe")
        XCTAssertFalse(EditKit.latin(session).contains("/ActualText"))
    }

    func test_aHitOnAllOfReplacementTextReplacesIt() throws {
        let session = try open(hello("/Span <</ActualText (hello world)>>"))
        XCTAssertEqual(try TextReplacer.replaceAll(session, "hello world", "bye").replaced, 1)
        XCTAssertEqual(try page(session, 0), "bye")
    }

    func test_aHitOverTwoSpansKeepsTheTextOutsideIt() throws {
        let session = try open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (say hello wor)>> BDC (say hello wor) Tj EMC " +
            "/Span <</ActualText (ld again)>> BDC (ld again) Tj EMC ET")
        let report = try TextReplacer.replaceAll(session, "world", "globe")
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(try page(session, 0), "say hello globe again")
        XCTAssertFalse(EditKit.latin(session).contains("/ActualText"))
    }

    func test_theMatchIsFoundThroughCaseAndAccentFolding() throws {
        let session = try open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (caf\\351 World)>> BDC (cafe World) Tj EMC ET")
        let report = try TextReplacer.replaceAll(session, "cafe", "tea", TextSearchOptions(foldDiacritics: true))
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(try page(session, 0), "tea World")
    }

    func test_aTaggedSpanKeepsItsTagAndPropertiesWhenReplaced() throws {
        for open in ["/P <</MCID 3 /Lang (en) /ActualText (hello world)>>", "/P /MC0"] {
            let session = try self.open(hello(open))
            XCTAssertEqual(try TextReplacer.replaceAll(session, "world", "globe").replaced, 1)
            XCTAssertEqual(try page(session, 0), "hello globe")
            XCTAssertFalse(EditKit.latin(session).contains("/ActualText"))
            let visitor = MarkedCollector()
            let document = try PdfDocument.open(session.current)
            ContentInterpreter(document).run(document.pages[0], visitor)
            XCTAssertTrue(visitor.marked.contains { $0.tag == "P" && $0.mcid != nil && $0.properties?.containsKey("Lang") == true }, open)
        }
    }

    func test_aSpanWithOnlyTheTextBecomesPlainMarkedContent() throws {
        let session = try open(hello("/Span <</ActualText (hello world)>>"))
        _ = try TextReplacer.replaceAll(session, "world", "globe")
        XCTAssertTrue(EditKit.latin(session).contains("/Span BMC"))
    }

    func test_everyEnclosingSpanIsNeutralized() throws {
        let session = try open("BT /F1 12 Tf 50 700 Td /Span <</ActualText (hello world)>> BDC /Span <</ActualText (hello)>> BDC (hello) Tj EMC ( world) Tj EMC ET")
        XCTAssertEqual(try TextReplacer.replaceAll(session, "world", "globe").replaced, 1)
        XCTAssertEqual(try page(session, 0), "hello globe")
        XCTAssertEqual(count(EditKit.latin(session), "/ActualText"), 0)
    }

    func test_deletingTaggedReplacementTextKeepsItsTag() throws {
        let session = try open(hello("/P <</MCID 3 /Lang (en) /ActualText (hello world)>>"))
        let editor = try PageEditor(session, 0)
        let blocks = try editor.objects.compactMap { $0 as? TextObject }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(try editor.deleteText(blocks[0].range).done)
        let content = EditKit.latin(session)
        XCTAssertTrue(content.contains("/MCID 3"))
        XCTAssertTrue(content.contains("/Lang (en)"))
        XCTAssertFalse(content.contains("/ActualText"))
        XCTAssertEqual(try page(session, 0), "")
    }
}
