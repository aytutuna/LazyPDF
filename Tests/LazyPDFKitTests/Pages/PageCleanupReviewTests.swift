import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageCleanupReviewTests.cs: the same cases.

final class PageCleanupReviewTests: XCTestCase {
    func test_aNewPageAtTheStartHasANumberedLabel() throws {
        let document = try PageTestFiles.open(3, "/PageLabels <</Nums [0 <</S /r>>]>>")
        try PageOperations.insertBlank(document, 0, 100, 100)
        let first = try XCTUnwrap(document.array(document.dict(document.catalog, "PageLabels"), "Nums")).items
        XCTAssertEqual(document.name(document.resolve(first[1]) as? PdfDictionary, "S"), "D")
    }

    func test_nameTreeLimitsFollowTheKeysThatRemain() throws {
        let free = PageTestFiles.free(3)
        let document = try PageTestFiles.open(3, "/Names <</Dests <</Kids [\(free) 0 R \(free + 1) 0 R]>>>>", add: { pdf in
            pdf.obj(free, "<</Limits [(a) (m)] /Names [(a) [4 0 R /Fit] (m) [5 0 R /Fit]]>>")
                .obj(free + 1, "<</Limits [(n) (z)] /Names [(n) [6 0 R /Fit] (z) [6 0 R /Fit]]>>")
        })
        try PageOperations.delete(document, [0, 2])
        let root = try XCTUnwrap(document.dict(document.dict(document.catalog, "Names"), "Dests"))
        XCTAssertEqual(PdfNameTree.read(document, root).map { $0.key }, ["m"])
        XCTAssertFalse(root.containsKey("Limits"))
    }

    func test_threadBeadsOnDeletedPagesLeaveTheirArticle() throws {
        let free = PageTestFiles.free(3)
        let document = try PageTestFiles.open(3, "/Threads [\(free) 0 R]", add: { pdf in
            pdf.obj(free, "<</Type /Thread /F \(free + 1) 0 R>>")
                .obj(free + 1, "<</Type /Bead /T \(free) 0 R /N \(free + 2) 0 R /V \(free + 2) 0 R /P 4 0 R /R [0 0 10 10]>>")
                .obj(free + 2, "<</Type /Bead /N \(free + 1) 0 R /V \(free + 1) 0 R /P 5 0 R /R [0 0 10 10]>>")
        })
        try PageOperations.delete(document, [0])
        let thread = try XCTUnwrap(document.resolve(document.array(document.catalog, "Threads")?.items[0]) as? PdfDictionary)
        let bead = try XCTUnwrap(document.resolve(thread["F"]) as? PdfDictionary)
        XCTAssertEqual(bead["P"] as? PdfReference, document.pages[0].reference)
        XCTAssertEqual(bead["N"] as? PdfReference, thread["F"] as? PdfReference)
    }

    func test_aGoToChainedAfterAnotherActionLosesItsDeadDestination() throws {
        let free = PageTestFiles.free(3)
        let document = try PageTestFiles.open(3, "/Outlines \(free) 0 R", add: { pdf in
            pdf.obj(free, "<</Type /Outlines /First \(free + 1) 0 R /Last \(free + 1) 0 R /Count 1>>")
                .obj(free + 1, "<</Title (x) /Parent \(free) 0 R /A <</S /URI /URI (http://x) /Next <</S /GoTo /D [5 0 R /Fit]>>>>>>")
        })
        try PageOperations.delete(document, [1])
        let action = try XCTUnwrap(document.get(free + 1) as? PdfDictionary)
        XCTAssertNil(document.dict(document.dict(action, "A"), "Next"))
    }

    func test_removingARadioButtonTakesItsOptionAndState() throws {
        let free = PageTestFiles.free(2)
        let document = try PageTestFiles.open(2, "/AcroForm <</Fields [\(free) 0 R]>>", pageExtra: { "/Annots [\(free + 1 + $0) 0 R]" }, add: { pdf in
            pdf.obj(free, "<</FT /Btn /Ff 49152 /T (r) /V /a /Opt [(A) (B)] /Kids [\(free + 1) 0 R \(free + 2) 0 R]>>")
                .obj(free + 1, "<</Type /Annot /Subtype /Widget /Parent \(free) 0 R /Rect [0 0 10 10] /AS /a /AP <</N <</a \(free + 3) 0 R /Off \(free + 3) 0 R>>>>>>")
                .obj(free + 2, "<</Type /Annot /Subtype /Widget /Parent \(free) 0 R /Rect [20 0 30 10] /AS /Off /AP <</N <</b \(free + 3) 0 R /Off \(free + 3) 0 R>>>>>>")
                .stream(free + 3, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "")
        })
        try PageOperations.delete(document, [0])
        let field = try XCTUnwrap(document.get(free) as? PdfDictionary)
        XCTAssertEqual(try XCTUnwrap(document.array(field, "Opt")).items.map { PdfText.read(document, $0) }, ["B"])
        XCTAssertEqual(document.name(field, "V"), "Off")
    }
}
