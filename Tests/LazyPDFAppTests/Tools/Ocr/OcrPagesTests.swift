import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/ocr/OcrPagesTests.cs. OcrLanguageStateTests are left out here: the language list
// belongs to Tools/Common and OcrLanguagesTests has its cases.

final class OcrPagesTests: XCTestCase {
    func test_pagesThatNeedReadingComeFirstInPageOrder() {
        let rows = OcrPages.rows([.text, .picture, .blank, .drawing, .picture, .ownLayer])

        XCTAssertEqual(rows.map(\.page), [1, 4, 3, 5, 0, 2])
    }

    func test_onlyScansAndDrawingsAreWantedUnlessLayersAreReplaced() {
        let own = PageRow(0, .ownLayer)

        XCTAssertTrue(OcrPages.wanted(PageRow(0, .picture), replace: false))
        XCTAssertFalse(OcrPages.wanted(PageRow(0, .text), replace: false))
        XCTAssertFalse(OcrPages.wanted(own, replace: false))
        XCTAssertTrue(OcrPages.wanted(own, replace: true))
    }

    func test_aRowSaysPageAndKindToAScreenReader() {
        XCTAssertEqual(PageRow(2, .picture).spoken, "Page 3, Scan")
    }

    func test_triageReadsACopyOfTheFile() throws {
        XCTAssertEqual(try OcrPages.classify(Pdfs.text(2), password: nil, certificate: nil), [.text, .text])
    }

    func test_aLockedFileIsOpenedWithItsPassword() throws {
        let bytes = try Pdfs.restricted(.none)

        XCTAssertEqual(try OcrPages.classify(bytes, password: "owner", certificate: nil), [.text])
    }
}
