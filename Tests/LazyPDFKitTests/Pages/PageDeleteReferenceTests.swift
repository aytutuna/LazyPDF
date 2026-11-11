import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageDeleteReferenceTests.cs: the same cases. What points at a page when it is
// deleted: bookmarks, links, named destinations, the open action.

final class PageDeleteReferenceTests: XCTestCase {
    // Pages are objects 4 to 7 (indexes 0 to 3).
    private let outline = 12

    private func open(_ catalogExtra: String, pageExtra: ((Int) -> String)? = nil, add: ((TestPdf) -> Void)? = nil) throws -> PdfDocument {
        let outline = self.outline
        return try PageTestFiles.open(4, catalogExtra, pageExtra: pageExtra, add: { pdf in
            pdf.obj(outline, "<</Type /Outlines /First \(outline + 1) 0 R /Last \(outline + 4) 0 R /Count 4>>")
            pdf.obj(outline + 1, "<</Title (One) /Parent \(outline) 0 R /Next \(outline + 2) 0 R /Dest [4 0 R /Fit]>>")
            pdf.obj(outline + 2, "<</Title (Two) /Parent \(outline) 0 R /Prev \(outline + 1) 0 R /Next \(outline + 3) 0 R /Dest [5 0 R /XYZ 0 0 0] /First \(outline + 5) 0 R /Last \(outline + 5) 0 R /Count 1>>")
            pdf.obj(outline + 3, "<</Title (Three) /Parent \(outline) 0 R /Prev \(outline + 2) 0 R /Next \(outline + 4) 0 R /A <</S /GoTo /D [7 0 R /Fit]>>>>")
            pdf.obj(outline + 4, "<</Title (Four) /Parent \(outline) 0 R /Prev \(outline + 3) 0 R /Dest (c)>>")
            pdf.obj(outline + 5, "<</Title (Child) /Parent \(outline + 2) 0 R /Dest [6 0 R /Fit]>>")
            add?(pdf)
        })
    }

    private let names = "/Dests <</a [5 0 R /Fit] /b [6 0 R /Fit]>> /Names <</Dests <</Names [(c) [5 0 R /Fit] (d) [6 0 R /Fit] (e) <</D [4 0 R /Fit]>>]>>>>"

    private func item(_ document: PdfDocument, _ offset: Int) throws -> PdfDictionary {
        try XCTUnwrap(document.get(outline + offset) as? PdfDictionary)
    }

    func test_bookmarksKeepTheirPlaceAndLoseTheDestinationOfADeletedPage() throws {
        let document = try open("/Outlines \(outline) 0 R \(names)")
        try PageOperations.delete(document, [1, 3])
        XCTAssertTrue(try item(document, 1).containsKey("Dest"))
        XCTAssertFalse(try item(document, 2).containsKey("Dest"))
        XCTAssertFalse(try item(document, 3).containsKey("A"))
        XCTAssertFalse(try item(document, 4).containsKey("Dest"))
        XCTAssertTrue(try item(document, 5).containsKey("Dest"))
        for n in 1...5 { XCTAssertTrue(try item(document, n).containsKey("Title"), "\(n)") }
        XCTAssertEqual(try item(document, 3)["Next"] as? PdfReference, PdfReference(outline + 4, 0))
    }

    func test_namedDestinationsOfDeletedPagesAreRemoved() throws {
        let document = try open("/Outlines \(outline) 0 R \(names)")
        try PageOperations.delete(document, [1])
        let old = try XCTUnwrap(document.dict(document.catalog, "Dests"))
        XCTAssertFalse(old.containsKey("a"))
        XCTAssertTrue(old.containsKey("b"))
        let list = try XCTUnwrap(document.array(document.dict(document.dict(document.catalog, "Names"), "Dests"), "Names")).items
        XCTAssertEqual(stride(from: 0, to: list.count, by: 2).map { PageTestFiles.text(list[$0]) }, ["d", "e"])
    }

    func test_aDestinationInANameTreeWithKidsIsFoundAndRemoved() throws {
        let tree = "/Names <</Dests <</Kids [<</Limits [(a) (c)] /Names [(a) [4 0 R /Fit] (c) [5 0 R /Fit]]>> <</Limits [(d) (e)] /Names [(e) [5 0 R /Fit]]>>]>>>>"
        let document = try open("/Outlines \(outline) 0 R \(tree)")
        try PageOperations.delete(document, [1])
        let root = try XCTUnwrap(document.dict(document.dict(document.catalog, "Names"), "Dests"))
        XCTAssertEqual(PdfNameTree.read(document, root).map { $0.key }, ["a"])
    }

    func test_linksOnOtherPagesLoseADestinationThatIsGone() throws {
        let link = PageTestFiles.free(4) + 10
        let document = try open("", pageExtra: { $0 == 0 ? "/Annots [\(link) 0 R \(link + 1) 0 R]" : "" }, add: { pdf in
            pdf.obj(link, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [6 0 R /Fit]>>")
            pdf.obj(link + 1, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /GoTo /D [5 0 R /Fit]>>>>")
        })
        try PageOperations.delete(document, [2])
        let gone = try XCTUnwrap(document.get(link) as? PdfDictionary)
        let kept = try XCTUnwrap(document.get(link + 1) as? PdfDictionary)
        XCTAssertFalse(gone.containsKey("Dest"))
        XCTAssertTrue(kept.containsKey("A"))
    }

    func test_aLinkToTheNextPageStillGoesThere() throws {
        let link = PageTestFiles.free(4) + 10
        let document = try open("", pageExtra: { $0 == 0 ? "/Annots [\(link) 0 R]" : "" }, add: { pdf in
            pdf.obj(link, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [6 0 R /Fit]>>")
        })
        try PageOperations.delete(document, [1])
        let again = try PdfDocument.open(try document.saveRewrite())
        let first = try XCTUnwrap(again.array(again.pages[0].dictionary, "Annots")).items[0]
        let annotation = try XCTUnwrap(again.resolve(first) as? PdfDictionary)
        XCTAssertEqual(PageDestinations.pageOf(again, annotation["Dest"]), again.pages[1].reference)
    }

    func test_theOpenActionOfADeletedPageGoes() throws {
        let gone = try open("/OpenAction [5 0 R /Fit]")
        try PageOperations.delete(gone, [1])
        XCTAssertFalse(gone.catalog.containsKey("OpenAction"))
        let action = try open("/OpenAction <</S /GoTo /D [6 0 R /Fit]>>")
        try PageOperations.delete(action, [1])
        XCTAssertTrue(action.catalog.containsKey("OpenAction"))
    }

    func test_aTaggedDocumentKeepsItsStructureWhenATaggedPageGoes() throws {
        let tags = "/StructTreeRoot 40 0 R /MarkInfo <</Marked true>>"
        let document = try open(tags, pageExtra: { "/StructParents \($0)" }, add: { $0.obj(40, "<</Type /StructTreeRoot>>") })
        try PageOperations.delete(document, [1])
        XCTAssertTrue(document.catalog.containsKey("StructTreeRoot"))
        XCTAssertTrue(document.catalog.containsKey("MarkInfo"))
        for page in document.pages { XCTAssertTrue(page.dictionary.containsKey("StructParents")) }
    }

    func test_theStructureStaysWhenNoTaggedPageGoes() throws {
        let document = try open("/StructTreeRoot 40 0 R", pageExtra: { $0 == 0 ? "" : "/StructParents \($0)" }, add: { $0.obj(40, "<</Type /StructTreeRoot>>") })
        try PageOperations.delete(document, [0])
        XCTAssertTrue(document.catalog.containsKey("StructTreeRoot"))
        for page in document.pages { XCTAssertTrue(page.dictionary.containsKey("StructParents")) }
    }

    func test_whatIsLeftReadsBackWithoutRepairs() throws {
        let document = try open("/Outlines \(outline) 0 R \(names) /OpenAction [5 0 R /Fit]")
        try PageOperations.delete(document, [1, 2])
        let again = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(again.repairs, [])
        XCTAssertEqual(again.pages.count, 2)
    }
}
