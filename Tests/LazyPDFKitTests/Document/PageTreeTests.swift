import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/PageTreeTests.cs: the same cases, and two for pages outliving or not outliving their document, which only Swift has.

final class PageTreeTests: XCTestCase {
    private func open(_ pdf: TestPdf) throws -> PdfDocument {
        try PdfDocument.open(pdf.finish())
    }

    func test_pagesComeInReadingOrderWithTheirReferences() throws {
        let document = try PdfDocument.open(TestPdf.simple(3))
        XCTAssertEqual(document.pages.count, 3)
        XCTAssertEqual(document.pages.map { $0.index }, [0, 1, 2])
        XCTAssertEqual(document.pages.map { $0.reference.number }, [3, 4, 5])
        assertSame(document.get(4), document.pages[1].dictionary)
        XCTAssertEqual(TestPdf.text(document.pages[1].contents()), "BT /F1 12 Tf (2) Tj ET")
    }

    func test_pagesTakeWhatTheirAncestorsSet() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R] /Count 2 /MediaBox [0 0 100 200] /Rotate 90 /Resources <</Font <<>>>>>>")
            .obj(3, "<</Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R] /Count 2 /CropBox [10 10 60 60]>>")
            .obj(4, "<</Type /Page /Parent 3 0 R>>")
            .obj(5, "<</Type /Page /Parent 3 0 R /Rotate 270 /MediaBox [0 0 50 50] /Resources <</XObject <<>>>>>>")
        let document = try open(pdf)
        let first = document.pages[0]
        XCTAssertEqual(first.mediaBox, PdfRect(0, 0, 100, 200))
        XCTAssertEqual(first.cropBox, PdfRect(10, 10, 60, 60))
        XCTAssertEqual(first.rotate, 90)
        XCTAssertEqual(first.resources?.containsKey("Font"), true)
        let second = document.pages[1]
        XCTAssertEqual(second.rotate, 270)
        XCTAssertEqual(second.resources?.containsKey("XObject"), true)
        XCTAssertEqual(second.cropBox, PdfRect(10, 10, 50, 50))
    }

    func test_boxesAreNormalizedAndDefaulted() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>")
            .obj(3, "<</Type /Page /MediaBox [300 400 0 0] /TrimBox [5 5 15 25] /Rotate 450 /UserUnit 2>>")
            .obj(4, "<</Type /Page /MediaBox [0 0 0 0] /CropBox [1 2] /Rotate -90 /UserUnit -3 /BleedBox (x)>>")
        let document = try open(pdf)
        let page = document.pages[0]
        XCTAssertEqual(page.mediaBox, PdfRect(0, 0, 300, 400))
        XCTAssertEqual(page.cropBox.right, 300)
        XCTAssertEqual(page.trimBox, PdfRect(5, 5, 15, 25))
        XCTAssertEqual(page.cropBox, page.artBox)
        XCTAssertEqual(page.rotate, 90)
        XCTAssertEqual(page.userUnit, 2)
        let junk = document.pages[1]
        XCTAssertEqual(junk.mediaBox, PdfRect(0, 0, 612, 792))
        XCTAssertEqual(junk.mediaBox, junk.cropBox)
        XCTAssertEqual(junk.mediaBox, junk.bleedBox)
        XCTAssertEqual(junk.rotate, 270)
        XCTAssertEqual(junk.userUnit, 1)
    }

    func test_aCycleCostsOnlyTheEntryThatLoops() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 2 0 R 4 0 R] /Count 2>>")
            .obj(3, "<</Type /Page /Parent 2 0 R>>")
            .obj(4, "<</Type /Pages /Parent 2 0 R /Kids [2 0 R 5 0 R]>>")
            .obj(5, "<</Type /Page /Parent 4 0 R>>")
        let document = try open(pdf)
        XCTAssertEqual(document.pages.map { $0.reference.number }, [3, 5])
        XCTAssertTrue(document.repairs.contains { $0.contains("loop") })
    }

    func test_wrongCountIsNoted() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R] /Count 40>>")
            .obj(3, "<</Type /Page>>")
        let document = try open(pdf)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertTrue(document.repairs.contains { $0.contains("40 pages") })
    }

    func test_missingTypesAndParentsAreTolerated() throws {
        let pdf = TestPdf()
            .obj(1, "<</Pages 2 0 R>>")
            .obj(2, "<</Kids [3 0 R 4 0 R]>>")
            .obj(3, "<</Contents 9 0 R /MediaBox [0 0 5 5]>>")
            .obj(4, "<</Kids [5 0 R]>>")
            .obj(5, "<</Resources <<>>>>")
        let document = try open(pdf)
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertEqual(document.pages[0].mediaBox.width, 5)
    }

    func test_junkInKidsIsSkipped() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 42 (text) null 77 0 R 6 0 R <</Type /Page>> 5 0 R 3 0 R] /Count 2>>")
            .obj(3, "<</Type /Page>>")
            .obj(5, "<</Type /Font /BaseFont /Helvetica>>")
            .obj(6, "[1 2 3]")
        let document = try open(pdf)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertTrue(document.repairs.contains { $0.contains("not pages") })
    }

    func test_aTreeThatHoldsNothingFallsBackToThePagesInTheFile() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids 3 0 R>>")
            .obj(3, "<</Type /Page>>")
        let document = try open(pdf)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertTrue(document.repairs.contains { $0.contains("found by scanning") })
    }

    func test_aDeepTreeIsStoppedAtTheCap() throws {
        let pdf = TestPdf().obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        for i in 2..<400 { pdf.obj(i, "<</Type /Pages /Kids [\(i + 1) 0 R]>>") }
        pdf.obj(400, "<</Type /Page>>")
        let document = try open(pdf)
        // Too deep to walk, so the page is found by scanning instead.
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertTrue(document.repairs.contains { $0.contains("scanning") })
    }

    func test_aPageListedTwiceCountsOnce() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>")
            .obj(3, "<</Type /Page>>")
            .obj(4, "<</Type /Pages /Kids [3 0 R]>>")
        XCTAssertEqual(try open(pdf).pages.count, 1)
    }

    func test_contentStreamsAreJoinedAndBadOnesLeftOut() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3>>")
            .obj(3, "<</Type /Page /Contents [6 0 R 77 0 R 7 0 R 8 0 R null 9 0 R]>>")
            .obj(4, "<</Type /Page /Contents 6 0 R>>")
            .obj(5, "<</Type /Page>>")
            .stream(6, "", "q")
            .stream(7, "", "Q")
            .stream(8, "/Filter /JBIG2Decode", "not a content stream")
            .obj(9, "(not a stream)")
        let document = try open(pdf)
        XCTAssertEqual(TestPdf.text(document.pages[0].contents()), "q\nQ")
        XCTAssertTrue(document.repairs.contains { $0.contains("Page 1: a content stream could not be read") })
        XCTAssertEqual(TestPdf.text(document.pages[1].contents()), "q")
        XCTAssertTrue(document.pages[2].contents().isEmpty)
    }

    func test_editedTreeIsWalkedAgainOnRequest() throws {
        let document = try PdfDocument.open(TestPdf.simple(3))
        XCTAssertEqual(document.pages.count, 3)
        let kids = try XCTUnwrap(document.array(document.dict(document.catalog, "Pages"), "Kids"))
        kids.items.remove(at: 0)
        XCTAssertEqual(document.pages.count, 3)
        document.refreshPages()
        XCTAssertEqual(document.pages.count, 2)
        kids.items.removeAll()
        document.refreshPages()
        XCTAssertTrue(document.pages.isEmpty)
    }

    private func firstPage() throws -> PdfPage {
        try PdfDocument.open(TestPdf.simple(2)).pages[0]
    }

    func test_aPageKeepsItsDocumentAlive() throws {
        let page = try firstPage()
        XCTAssertEqual(TestPdf.text(page.contents()), "BT /F1 12 Tf (1) Tj ET")
        XCTAssertEqual(page.index, 0)
    }

    func test_pagesDoNotKeepTheDocumentAliveForever() throws {
        weak var released: PdfDocument?
        do {
            let document = try PdfDocument.open(TestPdf.simple(2))
            released = document
            XCTAssertEqual(document.pages.count, 2)
            XCTAssertEqual(document.pages[1].index, 1)
        }
        XCTAssertNil(released)
    }
}
