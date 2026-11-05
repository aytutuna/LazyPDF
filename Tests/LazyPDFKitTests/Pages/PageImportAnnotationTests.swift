import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageImportAnnotationTests.cs: the same cases.

final class PageImportAnnotationTests: XCTestCase {
    // Page 4 (index 0) of PageImportTests.source with six annotations; page 5 is index 1, page 6 index 2.
    private let annots = "/Annots [40 0 R 41 0 R 42 0 R 43 0 R 44 0 R 45 0 R 46 0 R]"

    private func source() throws -> PdfDocument {
        try PdfDocument.open(PageImportTests.source(annots, "/Dests <</five [5 0 R /Fit]>>", { pdf in
            pdf.obj(40, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [5 0 R /Fit]>>")
                .obj(41, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /GoTo /D [6 0 R /Fit]>>>>")
                .obj(42, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest /five>>")
                .obj(43, "<</Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (note) /Popup 44 0 R /P 4 0 R /StructParent 3>>")
                .obj(44, "<</Type /Annot /Subtype /Popup /Rect [50 50 100 100] /Parent 43 0 R /Open true>>")
                .obj(45, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /URI /URI (http://example.com)>>>>")
                .obj(46, "<</Type /Annot /Subtype /Popup /Rect [50 50 100 100] /Parent 99 0 R>>")
        }))
    }

    private func annotationsOf(_ document: PdfDocument, _ page: Int) -> [PdfDictionary] {
        (document.array(document.pages[page].dictionary, "Annots")?.items ?? []).compactMap { document.resolve($0) as? PdfDictionary }
    }

    private func subtypes(_ annotations: [PdfDictionary]) -> String {
        annotations.map { annotation in
            let name = (annotation["Subtype"] as? PdfName)?.value ?? ""
            if annotation["Dest"] != nil { return name + "+D" }
            return name + (annotation["A"] is PdfDictionary ? "+A" : "")
        }.joined(separator: ",")
    }

    func test_linksToPagesThatCameAcrossFollowThemAndTheOthersAreDropped() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0, 1], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let annotations = annotationsOf(again, 1)
        // The link to page 5 (kept, repointed), the named one (made explicit), the note and its popup, the web link; not the link to page 6 nor the orphan popup.
        XCTAssertEqual(subtypes(annotations), "Link+D,Link+D,Text,Popup,Link+A")
        XCTAssertEqual(PageDestinations.pageOf(again, annotations[0]["Dest"]), again.pages[2].reference)
        XCTAssertEqual(PageDestinations.pageOf(again, annotations[1]["Dest"]), again.pages[2].reference)
        XCTAssertEqual((again.resolve(annotations[0]["Dest"]) as? PdfArray)?.items[1].description, "/Fit")
    }

    func test_linksToPagesThatStayBehindAreDroppedAndNothingFromThemComesAlong() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertEqual(subtypes(annotationsOf(again, 1)), "Text,Popup,Link+A")
        XCTAssertEqual(again.pages.count, 2)
        XCTAssertFalse(TestPdf.contains(try target.saveRewrite(), "Page 12"))
    }

    func test_aNoteKeepsItsPopupAndPointsAtTheNewPage() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let annotations = annotationsOf(again, 1)
        let note = try XCTUnwrap(annotations.first { again.name($0, "Subtype") == "Text" })
        let popup = try XCTUnwrap(annotations.first { again.name($0, "Subtype") == "Popup" })
        XCTAssertEqual(note["P"] as? PdfReference, again.pages[1].reference)
        assertSame(popup, again.resolve(note["Popup"]))
        assertSame(note, again.resolve(popup["Parent"]))
        XCTAssertFalse(note.containsKey("StructParent"))
    }

    func test_theSameAnnotationOnTwoCopiesOfAPageIsTwoAnnotations() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0, 0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let first = annotationsOf(again, 1)
        let second = annotationsOf(again, 2)
        XCTAssertEqual(first.count, second.count)
        XCTAssertFalse(first.contains { a in second.contains { $0 === a } })
        let text = try XCTUnwrap(second.first { again.name($0, "Subtype") == "Text" })
        XCTAssertEqual(text["P"] as? PdfReference, again.pages[2].reference)
    }
}
