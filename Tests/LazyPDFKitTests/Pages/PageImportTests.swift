import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageImportTests.cs: the same cases, except the two ArgumentOutOfRangeException lines
// of AtTheEndAndAtTheStartAreFine, which are preconditions in Swift and cannot be caught. The PdfPig read in Reopen has no twin.

final class PageImportTests: XCTestCase {
    /// A source with a nested tree: the root gives /MediaBox and /Resources, a node gives /Rotate. Pages 4 and 5 share an image
    /// and a font, page 6 inherits everything; page 4 has a bead and a tag.
    static func source(_ extra: String = "", _ catalogExtra: String = "", _ add: ((TestPdf) -> Void)? = nil, extra5: String = "") -> [UInt8] {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 30 0 R /Threads [21 0 R] " + catalogExtra + ">>")
            .obj(2, "<</Type /Pages /Kids [3 0 R] /Count 3 /MediaBox [0 0 300 400] /Resources <</Font <</F1 10 0 R>>>>>>")
            .obj(3, "<</Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R 6 0 R] /Count 3 /Rotate 90>>")
            .obj(4, "<</Type /Page /Parent 3 0 R /Contents 7 0 R /B [20 0 R] /StructParents 0 /Resources <</Font <</F1 10 0 R>> /XObject <</Im1 11 0 R>>>> " + extra + ">>")
            .obj(5, "<</Type /Page /Parent 3 0 R /Contents 8 0 R /Resources <</Font <</F1 10 0 R>> /XObject <</Im1 11 0 R>>>> " + extra5 + ">>")
            .obj(6, "<</Type /Page /Parent 3 0 R /Contents 9 0 R>>")
            .stream(7, "", "BT /F1 12 Tf (Page 11) Tj ET q /Im1 Do Q")
            .stream(8, "", "BT /F1 12 Tf (Page 12) Tj ET q /Im1 Do Q")
            .stream(9, "", "BT /F1 12 Tf (Page 13) Tj ET")
            .obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>")
            .stream(11, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", [UInt8]([0x80]))
            .obj(20, "<</Type /Bead /P 4 0 R /T 21 0 R /N 20 0 R /V 20 0 R>>")
            .obj(21, "<</Type /Thread /F 20 0 R>>")
            .obj(30, "<</Type /StructTreeRoot /K 31 0 R>>")
            .obj(31, "<</S /P /Pg 4 0 R /K 0>>")
        add?(pdf)
        return pdf.finish()
    }

    private func types(_ document: PdfDocument) -> [String: Int] {
        var counts: [String: Int] = [:]
        for number in document.objectNumbers {
            let dictionary: PdfDictionary?
            switch document.get(number) {
            case let stream as PdfStream: dictionary = stream.dictionary
            case let found as PdfDictionary: dictionary = found
            default: dictionary = nil
            }
            if let type = document.name(dictionary, "Type") { counts[type, default: 0] += 1 }
            if document.name(dictionary, "Subtype") == "Image" { counts["Image", default: 0] += 1 }
        }
        return counts
    }

    func test_pagesComeInAtTheIndexInTheOrderAsked() throws {
        let target = try PageTestFiles.open(2)
        try PageOperations.importPages(target, try PdfDocument.open(Self.source()), [2, 0], 1)
        XCTAssertEqual(PageTestFiles.order(target), [1, 13, 11, 2])
        XCTAssertEqual(try PageTestFiles.reopen(target), ["Page 1", "Page 13", "Page 11", "Page 2"])
    }

    func test_atTheEndAndAtTheStartAreFine() throws {
        let target = try PageTestFiles.open(1)
        let source = try PdfDocument.open(Self.source())
        try PageOperations.importPages(target, source, [0], 1)
        try PageOperations.importPages(target, source, [1], 0)
        XCTAssertEqual(PageTestFiles.order(target), [12, 1, 11])
        XCTAssertEqual(target.pages.count, 3)
    }

    func test_aFontAndAnImageUsedByManyPagesAreCopiedOnce() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(Self.source()), [0, 1, 2], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let counts = types(again)
        XCTAssertEqual(counts["Font"], 2)
        XCTAssertEqual(counts["Image"], 1)
    }

    func test_whatAPageInheritsIsWrittenOntoIt() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(Self.source()), [2], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let page = again.pages[1]
        XCTAssertTrue(page.dictionary.containsKey("MediaBox"))
        XCTAssertTrue(page.dictionary.containsKey("Rotate"))
        XCTAssertEqual(page.mediaBox, PdfRect(0, 0, 300, 400))
        XCTAssertEqual(page.rotate, 90)
        XCTAssertTrue(try XCTUnwrap(again.dict(page.dictionary, "Resources")).containsKey("Font"))
        XCTAssertEqual(again.pages[0].mediaBox, PdfRect(0, 0, 200, 300))
        XCTAssertEqual(again.pages[0].rotate, 0)
    }

    func test_theSourcesTreeTagsAndThreadsStayBehind() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(Self.source()), [0, 1, 2], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let counts = types(again)
        XCTAssertEqual(counts["Pages"], 1)
        XCTAssertEqual(counts["Page"], 4)
        XCTAssertNil(counts["Bead"])
        XCTAssertNil(counts["StructTreeRoot"])
        XCTAssertNil(counts["Thread"])
        for page in again.pages {
            XCTAssertFalse(page.dictionary.containsKey("StructParents") || page.dictionary.containsKey("B"))
            assertSame(again.dict(again.catalog, "Pages"), again.dict(page.dictionary, "Parent"))
        }
    }

    func test_thePagesCopiedStayIndependentOfTheSource() throws {
        let source = try PdfDocument.open(Self.source())
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, source, [0], 1)
        PageOperations.rotate(target, [1], 90)
        source.pages[0].dictionary["Rotate"] = PdfNumber(270)
        XCTAssertEqual(target.pages[1].rotate, 180)
        XCTAssertEqual(source.pages[0].rotate, 270)
    }

    func test_thePageIsRotatedTheWayItWas() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(Self.source()), [0], 1)
        XCTAssertEqual(target.pages[1].rotate, 90)
        PageOperations.rotate(target, [1], 90)
        XCTAssertEqual(target.pages[1].rotate, 180)
    }

    func test_theSamePageTwiceGivesTwoPagesThatShareTheirResources() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(Self.source()), [0, 0], 1)
        XCTAssertEqual(PageTestFiles.order(target), [1, 11, 11])
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertEqual(types(again)["Image"], 1)
    }

    func test_importsIntoOneDocumentFromTheDocumentItselfShareEverything() throws {
        let target = try PageTestFiles.open(2)
        try PageOperations.importPages(target, target, [1, 0], 2)
        XCTAssertEqual(PageTestFiles.order(target), [1, 2, 2, 1])
        XCTAssertEqual(types(try PdfDocument.open(try target.saveRewrite()))["Font"], 1)
    }

    func test_aCommittedImportIsOneStepAndUndoesCleanly() throws {
        let session = try PdfEditSession.open(PageTestFiles.make(2))
        try PageOperations.importPages(session.document, try PdfDocument.open(Self.source()), [0, 1], 2)
        let reopened = try PageTestFiles.commit(session, "Insert pages")
        XCTAssertEqual(PageTestFiles.order(reopened), [1, 2, 11, 12])
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(PageTestFiles.order(session.document), [1, 2])
    }
}
