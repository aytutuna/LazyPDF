import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/ContentStreamTests.cs: the same cases, except that the assertion of
// AnOperationWhoseOperatorIsInTheNextStreamMergesThem that PdfPig reads "Hello grand world" back has no twin. How the
// page's own streams are rewritten: one by one, merged only when an edit spans the break between two.

final class ContentStreamTests: XCTestCase {
    private func split(_ streams: String...) throws -> PdfEditSession {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        let refs = (0..<streams.count).map { "\(10 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents [\(refs)] /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.obj(5, EditKit.helvetica)
        for i in 0..<streams.count { pdf.stream(10 + i, i == 1 ? "/LazyPDF <</Id 1>>" : "", streams[i]) }
        return try PdfEditSession.open(pdf.finish())
    }

    private func numbers(_ session: PdfEditSession) -> [Int] {
        let document = session.document
        return (document.array(document.pages[0].dictionary, "Contents")?.items ?? []).compactMap { ($0 as? PdfReference)?.number }
    }

    func test_onlyTheStreamThatChangedIsReplacedAndItKeepsItsMarker() throws {
        let session = try split("0.5 g 10 10 50 50 re f", "BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET", "q 1 0 0 rg 100 100 20 20 re f Q")
        XCTAssertTrue(try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand").done)
        let found = numbers(session)
        XCTAssertEqual(found[0], 10)
        XCTAssertNotEqual(found[1], 11)
        XCTAssertEqual(found[2], 12)
        let document = session.document
        let middle = try XCTUnwrap(document.resolve(document.array(document.pages[0].dictionary, "Contents")?.items[1]) as? PdfStream)
        XCTAssertTrue(middle.dictionary.containsKey("LazyPDF"))
        XCTAssertTrue(try EditKit.text(session).contains("Hello grand world"))
    }

    func test_anOperationWhoseOperatorIsInTheNextStreamMergesThem() throws {
        let session = try split("0.5 g 10 10 50 50 re f", "BT /F1 12 Tf 50 700 Td (Hello brave world)", "Tj ET", "q 1 0 0 rg 100 100 20 20 re f Q")
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(try EditKit.text(session).contains("Hello grand world"))
        XCTAssertEqual(numbers(session).count, 3)
        XCTAssertEqual(numbers(session)[0], 10)
        XCTAssertEqual(numbers(session)[2], 13)
    }

    func test_aStreamAfterTheEditIsLeftAloneWhenTheEditIsInTheFirst() throws {
        let session = try split("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET", "q 1 0 0 rg 100 100 20 20 re f Q")
        XCTAssertTrue(try PageEditor(session, 0).replaceText(try EditKit.find(session, "world"), "there").done)
        XCTAssertEqual(numbers(session)[1], 11)
    }

    func test_contentAddedAtTheEndStartsFromACleanState() throws {
        let session = try split("q 3 0 0 3 0 0 cm BT /F1 12 Tf 10 100 Td (open) Tj", "5 w")
        let editor = try PageEditor(session, 0)
        XCTAssertTrue(try editor.addRectangle(PdfRect(200, 300, 260, 340), ShapeStyle(stroke: RgbColor(0, 0, 0))).done)
        let bounds = try EditPaint.paths(session)[0].path.bounds
        XCTAssertEqual(bounds, PdfRect(200, 300, 260, 340))
        XCTAssertEqual(try EditPaint.paths(session)[0].lineWidth, 1)
    }

    func test_aDuplicatedPageSharingItsContentIsNotEditedThroughTheOther() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.obj(5, EditKit.helvetica)
        pdf.stream(6, "", "BT /F1 12 Tf 50 700 Td (Shared text) Tj ET")
        let session = try PdfEditSession.open(pdf.finish())
        XCTAssertTrue(try PageEditor(session, 0).replaceText(try EditKit.find(session, "Shared"), "Edited").done)
        XCTAssertTrue(try EditKit.text(session, 0).contains("Edited text"))
        XCTAssertTrue(try EditKit.text(session, 1).contains("Shared text"))
    }

    func test_malformedContentIsReadAsFarAsItGoes() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj 1 2 3 foo ET\n(unterminated ] >> Tj")
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(try EditKit.text(session).contains("Hello grand world"))
        XCTAssertTrue(EditKit.latin(session).contains("1 2 3 foo ET"))
    }

    func test_aPageWithNoContentHasNothingToEdit() throws {
        let session = try EditKit.session("")
        let editor = try PageEditor(session, 0)
        XCTAssertTrue(try editor.objects.isEmpty)
        XCTAssertFalse(try editor.replaceText(TextRange(0, 3), "x").done)
        XCTAssertFalse(session.canUndo)
    }

    func test_fakeBoldTextIsReplacedWithBothCopies() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Bold word) Tj ET\nBT /F1 12 Tf 50.3 700 Td (Bold word) Tj ET")
        XCTAssertTrue(try PageEditor(session, 0).replaceText(try EditKit.find(session, "word"), "text").done)
        let drawn = try EditKit.glyphs(session).map { $0.text }.joined()
        XCTAssertEqual(drawn, "Bold textBold text")
    }
}
