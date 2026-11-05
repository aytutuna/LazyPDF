import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageReviewTests.cs: the same cases.

final class PageReviewTests: XCTestCase {
    private func importing(_ source: PdfDocument, _ pages: [Int]) throws -> PdfDocument {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, source, pages, 1)
        return try PdfDocument.open(try target.saveRewrite())
    }

    func test_annotationsWrittenDirectlyInAnnotsComeAcross() throws {
        let source = try PageTestFiles.open(1, pageExtra: { _ in "/Annots [<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /URI /URI (http://example.com)>>>>]" })
        let again = try importing(source, [0])
        let annots = try XCTUnwrap(again.array(again.pages[1].dictionary, "Annots"))
        XCTAssertEqual(annots.items.count, 1)
        XCTAssertEqual(again.name(again.resolve(annots.items[0]) as? PdfDictionary, "Subtype"), "Link")
    }

    func test_aResetActionDoesNotCarryFieldsOfPagesThatStayBehind() throws {
        let source = try PageTestFiles.open(2, "/AcroForm <</Fields [40 0 R 41 0 R]>>", pageExtra: { $0 == 0 ? "/Annots [40 0 R]" : "/Annots [41 0 R]" }, add: { pdf in
            pdf.obj(40, "<</Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (reset) /Rect [0 0 50 20] /A <</S /ResetForm /Fields [41 0 R]>>>>")
                .obj(41, "<</Type /Annot /Subtype /Widget /FT /Tx /T (salary) /V (secretvalue) /Rect [0 50 50 70]>>")
        })
        let again = try importing(source, [0])
        XCTAssertFalse(TestPdf.contains(try again.saveRewrite(), "secretvalue"))
    }

    func test_hiddenLayersStayHiddenInTheCopy() throws {
        let source = try PageTestFiles.open(1, "/OCProperties <</OCGs [40 0 R] /D <</OFF [40 0 R]>>>>", pageExtra: { _ in "/Annots [41 0 R]" }, add: { pdf in
            pdf.obj(40, "<</Type /OCG /Name (Hidden)>>")
                .obj(41, "<</Type /Annot /Subtype /Square /Rect [0 0 10 10] /OC 40 0 R>>")
        })
        let again = try importing(source, [0])
        let layers = PdfLayers.read(again)
        XCTAssertEqual(layers.layers.count, 1)
        XCTAssertFalse(try XCTUnwrap(layers.layers.first).isOn)
    }

    func test_aFormKeepsOnlyTheResourcesItsOwnContentNames() throws {
        let source = try PageTestFiles.open(1, pageExtra: { _ in "/Annots [40 0 R]" }, add: { pdf in
            pdf.obj(40, "<</Type /Annot /Subtype /Square /Rect [0 0 10 10] /AP <</N 41 0 R>>>>")
                .stream(41, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources 42 0 R", "BT /F1 12 Tf (x) Tj ET")
                .obj(42, "<</Font <</F1 3 0 R>> /XObject <</Im9 43 0 R>>>>")
                .stream(43, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "UNIQUEIMG")
        })
        let part = try PageAssembly.extract(source, [0])
        XCTAssertFalse(TestPdf.contains(try part.saveRewrite(), "UNIQUEIMG"))
    }
}
