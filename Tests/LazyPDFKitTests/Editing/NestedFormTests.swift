import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/NestedFormTests.cs: the same cases, except that the two assertions of
// AnInnerFormUsedTwiceIsCopiedForTheOneEdited that PdfPig reads the words back have no twin. A form inside a form: the
// copy of the inner one is pointed at from the outer one, which is edited in place or copied in turn.

final class NestedFormTests: XCTestCase {
    private func open(_ outerContent: String, _ pages: Int = 1) throws -> PdfEditSession {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<pages).map { "\(10 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages) /MediaBox [0 0 600 800]>>")
        pdf.obj(5, EditKit.helvetica)
        pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 10 50 Td (Inner text) Tj ET")
        pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</In 7 0 R>>>>", outerContent)
        for i in 0..<pages {
            pdf.obj(10 + i, "<</Type /Page /Parent 2 0 R /Contents \(30 + i) 0 R /Resources <</XObject <</Out 8 0 R>>>>>>")
            pdf.stream(30 + i, "", "q 1 0 0 1 100 500 cm /Out Do Q")
        }
        return try PdfEditSession.open(pdf.finish())
    }

    private func rows(_ session: PdfEditSession, _ page: Int = 0) -> [String] {
        TextPage.create(session.document, session.document.pages[page]).lines.sorted { $0.bounds.top > $1.bounds.top }.map { $0.text }
    }

    func test_aChainOfSingleUsesIsEditedInPlace() throws {
        let session = try open("q 1 0 0 1 20 20 cm /In Do Q")
        let editor = PageEditor(session, 0)
        let block = try XCTUnwrap(try assertSingle(editor.objects) as? TextObject)
        XCTAssertEqual(block.forms.count, 2)
        XCTAssertTrue(try editor.replaceText(editor.text.lines[0].range, "Changed").done)
        XCTAssertEqual(rows(session), ["Changed"])
        let xobject = try XCTUnwrap(session.document.dict(session.document.pages[0].resources, "XObject"))
        XCTAssertEqual((xobject["Out"] as? PdfReference)?.number, 8)
        XCTAssertEqual(xobject.count, 1)
    }

    func test_anInnerFormUsedTwiceIsCopiedForTheOneEdited() throws {
        let session = try open("q 1 0 0 1 20 20 cm /In Do Q q 1 0 0 1 20 220 cm /In Do Q")
        let editor = PageEditor(session, 0)
        let top = try XCTUnwrap(editor.text.lines.sorted { $0.bounds.top > $1.bounds.top }.first)
        XCTAssertTrue(try editor.replaceText(top.range, "Changed").done)
        XCTAssertEqual(rows(session), ["Changed", "Inner text"])
    }

    func test_bothLevelsSharedBetweenPagesAreCopied() throws {
        let session = try open("q 1 0 0 1 20 20 cm /In Do Q", 2)
        XCTAssertTrue(try PageEditor(session, 0).replaceText(PageEditor(session, 0).text.lines[0].range, "Changed").done)
        XCTAssertEqual(rows(session, 0), ["Changed"])
        XCTAssertEqual(rows(session, 1), ["Inner text"])
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(rows(session, 0), ["Inner text"])
    }
}
