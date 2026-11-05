import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageBoxTests.cs: the same cases. The ArgumentException line of
// NullRemovesABoxExceptTheMediaBox is a precondition in Swift and cannot be caught.

final class PageBoxTests: XCTestCase {
    func test_boxesAreSetOnTheChosenPagesOnly() throws {
        let document = try PageTestFiles.open(2)
        try PageOperations.setBox(document, [1], .crop, PdfRect(10, 20, 110, 220))
        try PageOperations.setBox(document, [0, 1], .trim, PdfRect(20, 30, 100, 200))
        try PageOperations.setBox(document, [0], .bleed, PdfRect(5, 5, 195, 295))
        try PageOperations.setBox(document, [1], .art, PdfRect(30, 40, 90, 100))
        XCTAssertEqual(document.pages[0].cropBox, PdfRect(0, 0, 200, 300))
        XCTAssertEqual(document.pages[1].cropBox, PdfRect(10, 20, 110, 220))
        XCTAssertEqual(document.pages[0].trimBox, PdfRect(20, 30, 100, 200))
        XCTAssertEqual(document.pages[0].bleedBox, PdfRect(5, 5, 195, 295))
        XCTAssertEqual(document.pages[1].artBox, PdfRect(30, 40, 90, 100))
    }

    func test_mediaBoxReplacesWhatTheTreeGave() throws {
        let document = try PageTestFiles.open(2)
        try PageOperations.setBox(document, [0], .media, PdfRect(0, 0, 400, 500))
        XCTAssertEqual(document.pages[0].mediaBox, PdfRect(0, 0, 400, 500))
        XCTAssertEqual(document.pages[1].mediaBox, PdfRect(0, 0, 200, 300))
    }

    func test_aBoxIsClippedToThePaperAndRefusedWhenItMissesIt() throws {
        let document = try PageTestFiles.open(1)
        try PageOperations.setBox(document, [0], .crop, PdfRect(100, 100, 500, 500))
        XCTAssertEqual(document.pages[0].cropBox, PdfRect(100, 100, 200, 300))
        XCTAssertEqual(document.rect(document.pages[0].dictionary["CropBox"]), PdfRect(100, 100, 200, 300))
        XCTAssertThrowsError(try PageOperations.setBox(document, [0], .art, PdfRect(400, 400, 500, 500)))
        XCTAssertThrowsError(try PageOperations.setBox(document, [0], .trim, PdfRect(10, 10, 10, 50)))
    }

    func test_nullRemovesABoxExceptTheMediaBox() throws {
        let document = try PageTestFiles.open(1, pageExtra: { _ in "/CropBox [10 10 50 50] /TrimBox [10 10 50 50]" })
        try PageOperations.setBox(document, [0], .crop, nil)
        try PageOperations.setBox(document, [0], .trim, nil)
        XCTAssertFalse(document.pages[0].dictionary.containsKey("CropBox"))
        XCTAssertEqual(document.pages[0].trimBox, PdfRect(0, 0, 200, 300))
    }

    func test_changingTheBoxKeepsTheContentAndMovesNothing() throws {
        let document = try PageTestFiles.open(1, pageExtra: { _ in "/TrimBox [10 10 50 50]" })
        try PageOperations.resize(document, [0], 100, 150, .changeBox)
        let page = document.pages[0]
        XCTAssertEqual(page.mediaBox, PdfRect(0, 0, 100, 150))
        XCTAssertEqual(page.cropBox, page.mediaBox)
        XCTAssertFalse(page.dictionary.containsKey("TrimBox"))
        XCTAssertEqual(Latin1.string(page.contents()), "BT /F1 12 Tf 20 100 Td (Page 1) Tj ET")
    }

    func test_scalingWrapsTheContentInAMatrixThatFitsAndCentres() throws {
        let document = try PageTestFiles.open(1, pageExtra: { _ in "/TrimBox [0 0 100 150] /Annots [<</Type /Annot /Subtype /Square /Rect [20 30 40 60]>>]" })
        try PageOperations.resize(document, [0], 400, 300, .scaleContent)
        let page = document.pages[0]
        XCTAssertEqual(page.mediaBox, PdfRect(0, 0, 400, 300))
        XCTAssertEqual(page.cropBox, PdfRect(0, 0, 400, 300))
        // 200 x 300 into 400 x 300: scale 1, 100 to each side.
        XCTAssertEqual(Latin1.string(page.contents()), "q 1 0 0 1 100 0 cm\n\nBT /F1 12 Tf 20 100 Td (Page 1) Tj ET\n\nQ")
        XCTAssertEqual(page.trimBox, PdfRect(100, 0, 200, 150))
        let annotation = try XCTUnwrap(document.array(page.dictionary, "Annots")?.items.first as? PdfDictionary)
        XCTAssertEqual(document.rect(annotation["Rect"]), PdfRect(120, 30, 140, 60))
    }

    func test_scalingDownKeepsTheAspectRatio() throws {
        let document = try PageTestFiles.open(1)
        try PageOperations.resize(document, [0], 100, 300, .scaleContent)
        XCTAssertTrue(Latin1.string(document.pages[0].contents()).hasPrefix("q 0.5 0 0 0.5 0 75 cm"))
    }

    func test_aTurnedPageIsSizedAsItIsShown() throws {
        let document = try PageTestFiles.open(1, pageExtra: { _ in "/Rotate 90" })
        try PageOperations.resize(document, [0], 400, 100, .changeBox)
        let page = document.pages[0]
        XCTAssertEqual(page.mediaBox, PdfRect(0, 0, 100, 400))
        let shown = PageGeometry(page)
        XCTAssertEqual(shown.width, 400, accuracy: 1e-6)
        XCTAssertEqual(shown.height, 100, accuracy: 1e-6)
    }

    func test_transitionsAndAdvanceTimesAreRemoved() throws {
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Trans <</S /Wipe>> /Dur 5" : "" })
        PageOperations.removeTransitions(document, [0, 1])
        for page in document.pages {
            XCTAssertFalse(page.dictionary.containsKey("Trans") || page.dictionary.containsKey("Dur"))
        }
    }

    func test_removingABoxKeepsPagesThatWereFoundByScanning() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [] /Count 0>>")
            .obj(3, "<</Type /Page /MediaBox [0 0 200 300] /CropBox [10 10 50 50]>>")
            .obj(4, "<</Type /Page /MediaBox [0 0 200 300]>>")
        let document = try PdfDocument.open(pdf.finish("/Root 1 0 R"))
        XCTAssertEqual(document.pages.count, 2)
        try PageOperations.setBox(document, [0], .crop, nil)
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertEqual(document.pages[0].cropBox, PdfRect(0, 0, 200, 300))
        PageOperations.rotate(document, [1], 90)
        XCTAssertEqual(document.pages[1].rotate, 90)
    }

    func test_aSizeThatCannotBeAPageIsRefused() throws {
        for (width, height) in [(0.0, 100.0), (100.0, -1.0), (20000.0, 100.0), (Double.nan, 100.0)] {
            let document = try PageTestFiles.open(1)
            XCTAssertThrowsError(try PageOperations.resize(document, [0], width, height, .changeBox), "\(width) x \(height)")
        }
    }
}
