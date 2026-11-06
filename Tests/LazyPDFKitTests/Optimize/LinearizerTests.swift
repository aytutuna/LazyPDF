import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/LinearizerTests.cs: the same cases. PdfPig text comparisons have no twin;
// the engine's own text (LinearizerKit.textText) stands in for them.

final class LinearizerTests: XCTestCase {
    func test_layoutAndHintTablesDescribeTheFile() throws {
        for pages in [1, 2, 5, 40] {
            let source = try PdfDocument.open(LinearizerKit.make(pages))
            let file = LinearizerKit.keep("basic-\(pages)", try source.saveLinearized())
            let parameters = try LinearizerKit.verify(file)
            XCTAssertEqual(pages, parameters["N"])
        }
    }

    func test_textAndPagesSurvive() throws {
        let source = try PdfDocument.open(LinearizerKit.make(7))
        let file = try source.saveLinearized()
        let again = try PdfDocument.open(file)
        XCTAssertEqual(7, again.pages.count)
        for i in 0..<7 { XCTAssertEqual(source.pages[i].contents(), again.pages[i].contents()) }
        XCTAssertEqual(LinearizerKit.textText(source), LinearizerKit.textText(again))
        XCTAssertEqual("Linearizer test", Latin1.string((again.info?["Title"] as? PdfString)?.bytes ?? []))
        XCTAssertEqual(source.id[0], again.id[0])
    }

    func test_inheritedAttributesMoveOntoThePages() throws {
        let source = try PdfDocument.open(LinearizerKit.make(4))
        let again = try PdfDocument.open(try source.saveLinearized())
        XCTAssertEqual(false, again.dict(again.catalog, "Pages")?.containsKey("Resources"))
        XCTAssertEqual(false, again.dict(again.catalog, "Pages")?.containsKey("MediaBox"))
        for page in again.pages {
            XCTAssertTrue(page.dictionary.containsKey("Resources"))
            XCTAssertTrue(page.dictionary.containsKey("MediaBox"))
            XCTAssertEqual(200, page.mediaBox.width)
        }
        // One resources object serves the pages that had none of their own.
        XCTAssertEqual(again.pages[0].dictionary["Resources"] as? PdfReference, again.pages[2].dictionary["Resources"] as? PdfReference)
    }

    func test_aDirectInheritedDictionaryBecomesOneSharedObject() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 90 90] /Resources <</Font <</F1 6 0 R>>>>>>")
        for i in 0..<3 { pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(7 + i) 0 R>>") }
        pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        for i in 0..<3 { pdf.stream(7 + i, "", "BT /F1 12 Tf 10 10 Td (Sheet \(i)) Tj ET") }
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        let resources = again.pages.map { $0.dictionary["Resources"] }
        XCTAssertTrue(resources.allSatisfy { $0 is PdfReference })
        XCTAssertEqual(1, Set(resources.compactMap { ($0 as? PdfReference)?.number }).count)
        XCTAssertTrue(try LinearizerKit.textText(file).contains("Sheet 2"))
    }

    func test_anObjectOnlyTheFirstPageUsesStaysInItsSection() throws {
        let file = try PdfDocument.open(LinearizerKit.make(5)).saveLinearized()
        let parameters = try LinearizerKit.verify(file)
        // Page 1 has no font of its own; the shared font and form are in the first section because page 1 uses them.
        let courier = OptimizeKit.indexOf(file, Latin1.bytes("/Courier"))
        XCTAssertTrue(courier > (parameters["E"] ?? 0), "a font of page 2 is behind the first page")
        let helvetica = OptimizeKit.indexOf(file, Latin1.bytes("/Helvetica"))
        XCTAssertTrue(helvetica >= 1 && helvetica <= (parameters["E"] ?? 0))
    }

    func test_aLinkToAnotherPageDoesNotPullItIn() throws {
        let source = try PdfDocument.open(LinearizerKit.make(6))
        let file = try source.saveLinearized()
        let document = try PdfDocument.open(file)
        // Page 3 (index 2) holds no object of page 4, whose link it carries.
        let reach = LinearizerKit.reach(document, document.pages[2].reference.number)
        XCTAssertFalse(reach.contains(document.pages[3].reference.number))
        try LinearizerKit.verify(file)
    }

    func test_theBookmarksJoinTheFirstPageWhenTheFileOpensOnThem() throws {
        let file = try PdfDocument.open(LinearizerKit.make(3)).saveLinearized()
        let parameters = try LinearizerKit.verify(file)
        let document = try PdfDocument.open(file)
        let outlines = try XCTUnwrap((document.catalog["Outlines"] as? PdfReference)?.number)
        let at = OptimizeKit.indexOf(file, Latin1.bytes("\n\(outlines) 0 obj\n")) + 1
        let h0 = try XCTUnwrap(parameters["H0"])
        XCTAssertTrue(at >= h0 && at <= (parameters["E"] ?? 0))
        XCTAssertTrue(Latin1.string(Array(file[h0..<h0 + 40])).contains("/O "))
    }

    func test_aLinearizedFileCanBeLinearizedAgain() throws {
        let once = try PdfDocument.open(LinearizerKit.make(6)).saveLinearized()
        let twice = try PdfDocument.open(once).saveLinearized()
        try LinearizerKit.verify(twice)
        XCTAssertEqual(try LinearizerKit.textText(once), try LinearizerKit.textText(twice))
    }

    func test_aDocumentWithoutPagesIsRefused() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertThrowsError(try document.saveLinearized()) { XCTAssertTrue($0 is InvalidOperationException, "\($0)") }
    }

    func test_theHeaderVersionIsRaisedToWhatLinearizationNeeds() throws {
        let file = try PdfDocument.open(LinearizerKit.make(2, "%PDF-1.0\n")).saveLinearized()
        XCTAssertTrue(Latin1.string(file).hasPrefix("%PDF-1.2\n"))
    }
}
