import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/FormTextTests.cs: the same cases, except that the two assertions of
// AFormPaintedTwiceIsCopiedForTheOneThatWasEdited that PdfPig reads the words back have no twin. Text inside a form
// XObject: edited in place when nothing else uses the form, in a copy when something does.

final class FormTextTests: XCTestCase {
    private let formContent = "BT /F1 12 Tf 10 50 Td (Form text here) Tj ET"
    private let formDictionary = "/Type /XObject /Subtype /Form /BBox [0 0 300 100] /Resources <</Font <</F1 5 0 R>>>>"

    private func pages(_ pageCount: Int, _ pageContent: String, _ sharedResources: String? = nil) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<pageCount).map { "\(10 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pageCount) /MediaBox [0 0 600 800]>>")
        pdf.obj(5, EditKit.helvetica)
        pdf.stream(7, formDictionary, formContent)
        for i in 0..<pageCount {
            let resources = sharedResources == nil ? "/Resources <</XObject <</Fm1 7 0 R>>>>" : "/Resources 9 0 R"
            pdf.obj(10 + i, "<</Type /Page /Parent 2 0 R /Contents \(20 + i) 0 R \(resources)>>")
            pdf.stream(20 + i, "", pageContent)
        }
        if let sharedResources { pdf.obj(9, sharedResources) }
        pdf.obj(3, "null")
        pdf.obj(4, "null")
        pdf.obj(6, "null")
        pdf.obj(8, "null")
        return pdf.finish()
    }

    private func formText(_ session: PdfEditSession, _ page: Int, _ index: Int = 0) -> String {
        let text = TextPage.create(session.document, session.document.pages[page])
        return text.lines[index].text
    }

    func test_aFormOnlyOneUserPaintsIsEditedInPlace() throws {
        let session = try PdfEditSession.open(pages(1, "q 1 0 0 1 50 600 cm /Fm1 Do Q"))
        let page = EditKit.latin(session)
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "text"), "word")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertEqual(formText(session, 0), "Form word here")
        XCTAssertEqual(page, EditKit.latin(session))
        let xobjects = try XCTUnwrap(session.document.dict(session.document.pages[0].resources, "XObject"))
        XCTAssertEqual((xobjects["Fm1"] as? PdfReference)?.number, 7)
    }

    func test_aFormPaintedTwiceIsCopiedForTheOneThatWasEdited() throws {
        let session = try PdfEditSession.open(pages(1, "q 1 0 0 1 50 600 cm /Fm1 Do Q q 1 0 0 1 50 400 cm /Fm1 Do Q"))
        let editor = try PageEditor(session, 0)
        let top = try XCTUnwrap(try editor.text.lines.sorted { $0.bounds.top > $1.bounds.top }.first)
        let result = try editor.replaceText(TextRange(top.range.start + 5, top.range.start + 9), "word")
        XCTAssertTrue(result.done, result.problem ?? "")
        let lines = TextPage.create(session.document, session.document.pages[0]).lines.sorted { $0.bounds.top > $1.bounds.top }.map { $0.text }
        XCTAssertEqual(lines, ["Form word here", "Form text here"])
        let xobjects = try XCTUnwrap(session.document.dict(session.document.pages[0].resources, "XObject"))
        XCTAssertEqual((xobjects["Fm1"] as? PdfReference)?.number, 7)
        XCTAssertEqual(xobjects.count, 2)
    }

    func test_aFormTwoPagesShareIsCopiedAndTheOtherPageKeepsItsText() throws {
        let session = try PdfEditSession.open(pages(2, "q 1 0 0 1 50 600 cm /Fm1 Do Q"))
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "text"), "word")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertEqual(formText(session, 0), "Form word here")
        XCTAssertEqual(formText(session, 1), "Form text here")
    }

    func test_resourcesTwoPagesShareAreNotChangedUnderThem() throws {
        let session = try PdfEditSession.open(pages(2, "q 1 0 0 1 50 600 cm /Fm1 Do Q", "<</XObject <</Fm1 7 0 R>>>>"))
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "text"), "word")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertEqual(formText(session, 0), "Form word here")
        XCTAssertEqual(formText(session, 1), "Form text here")
    }

    func test_objectsInAFormMoveWithAMatrixInTheForm() throws {
        let session = try PdfEditSession.open(pages(1, "q 2 0 0 2 50 600 cm /Fm1 Do Q"))
        let editor = try PageEditor(session, 0)
        let block = try XCTUnwrap(try assertSingle(try editor.objects) as? TextObject)
        XCTAssertEqual(block.forms.count, 1)
        let before = try EditKit.glyphs(session)
        let result = try editor.move([block], 30, -10)
        XCTAssertTrue(result.done)
        let after = try EditKit.glyphs(session)
        XCTAssertEqual(before.count, after.count)
        for (a, b) in zip(before, after) {
            XCTAssertEqual(a.x + 30, b.x, accuracy: 0.005)
            XCTAssertEqual(a.y - 10, b.y, accuracy: 0.005)
        }
        XCTAssertEqual(formText(session, 0), "Form text here")
    }
}
