import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageInsertTests.cs: the same cases. The ArgumentOutOfRangeException lines for
// the position and the count in BlankPagesGoWhereAsked are preconditions in Swift and cannot be caught. The PdfPig read in Reopen has no twin.

final class PageInsertTests: XCTestCase {
    func test_blankPagesHaveTheSizeAndNoContent() throws {
        let document = try PageTestFiles.open(2, rootExtra: "/Rotate 90")
        try PageOperations.insertBlank(document, 1, 595, 842, 2)
        XCTAssertEqual(document.pages.count, 4)
        let blank = document.pages[1]
        XCTAssertEqual(blank.mediaBox, PdfRect(0, 0, 595, 842))
        XCTAssertEqual(blank.rotate, 0)
        XCTAssertTrue(blank.contents().isEmpty)
        XCTAssertEqual(document.pages[2].mediaBox, blank.mediaBox)
        try PageTestFiles.reopen(document)
    }

    func test_blankPagesGoWhereAsked() throws {
        let document = try PageTestFiles.open(2)
        try PageOperations.insertBlank(document, 0, 100, 100)
        try PageOperations.insertBlank(document, 3, 100, 100)
        XCTAssertEqual(document.pages.count, 4)
        XCTAssertEqual(document.pages.map { Int($0.mediaBox.width) }, [100, 200, 200, 100])
        XCTAssertThrowsError(try PageOperations.insertBlank(document, 0, 0, 100))
    }

    func test_aBlankPageNextToABigPageStillRefusesASizeAboveTheLimit() throws {
        let document = try PageTestFiles.open(1, pageExtra: { _ in "/MediaBox [0 0 2000 2000] /UserUnit 10" })
        let shown = PageGeometry(document.pages[0])
        XCTAssertEqual(shown.width, 20000, accuracy: 1e-6)
        XCTAssertThrowsError(try PageOperations.insertBlank(document, 1, shown.width, shown.height))
        XCTAssertEqual(document.pages.count, 1)
    }

    func test_aDuplicateFollowsItsOriginalAndSharesTheContent() throws {
        let document = try PageTestFiles.open(3)
        try PageOperations.duplicate(document, [0, 2])
        XCTAssertEqual(PageTestFiles.order(document), [1, 1, 2, 3, 3])
        let pages = document.pages
        XCTAssertNotEqual(pages[0].reference, pages[1].reference)
        XCTAssertEqual(pages[0].dictionary["Contents"]?.description, pages[1].dictionary["Contents"]?.description)
        XCTAssertEqual(try PageTestFiles.reopen(document), ["Page 1", "Page 1", "Page 2", "Page 3", "Page 3"])
    }

    func test_aDuplicateCopiesItsAnnotationsAndLeavesThePopupWithItsOwner() throws {
        let n = PageTestFiles.free(1)
        let document = try PageTestFiles.open(1, pageExtra: { _ in "/Annots [\(n) 0 R \(n + 1) 0 R]" }, add: { pdf in
            pdf.obj(n, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note) /Popup \(n + 1) 0 R /P \(PageTestFiles.pageObject(0)) 0 R>>")
            pdf.obj(n + 1, "<</Type /Annot /Subtype /Popup /Rect [40 40 100 100] /Parent \(n) 0 R>>")
        })
        try PageOperations.duplicate(document, [0])
        let first = try XCTUnwrap(document.array(document.pages[0].dictionary, "Annots")).items.compactMap { $0 as? PdfReference }
        let second = try XCTUnwrap(document.array(document.pages[1].dictionary, "Annots")).items.compactMap { $0 as? PdfReference }
        XCTAssertEqual(Set(first).intersection(second), [])
        let text = try XCTUnwrap(document.resolve(second[0]) as? PdfDictionary)
        XCTAssertEqual(PageTestFiles.text(text["Contents"]), "note")
        XCTAssertEqual(text["Popup"] as? PdfReference, second[1])
        XCTAssertEqual(text["P"] as? PdfReference, document.pages[1].reference)
        let popup = try XCTUnwrap(document.resolve(second[1]) as? PdfDictionary)
        XCTAssertEqual(popup["Parent"] as? PdfReference, second[0])
    }

    func test_pageLabelsMakeRoomForInsertedPages() throws {
        let document = try PageTestFiles.open(4, "/PageLabels <</Nums [0 <</S /r>> 2 <</S /D>>]>>")
        try PageOperations.insertBlank(document, 2, 100, 100)
        let nums = try XCTUnwrap(document.array(document.dict(document.catalog, "PageLabels"), "Nums")).items
        XCTAssertEqual([0, 2].map { (nums[$0] as? PdfNumber)?.integer }, [0, 3])
    }

    func test_insertingAtTheStartKeepsAFirstLabelRange() throws {
        let document = try PageTestFiles.open(2, "/PageLabels <</Nums [0 <</S /D>>]>>")
        try PageOperations.insertBlank(document, 0, 100, 100)
        let nums = try XCTUnwrap(document.array(document.dict(document.catalog, "PageLabels"), "Nums")).items
        XCTAssertEqual((nums[0] as? PdfNumber)?.integer, 0)
        XCTAssertEqual((nums[2] as? PdfNumber)?.integer, 1)
    }
}
