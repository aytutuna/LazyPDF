#if os(macOS)
import XCTest
import AppKit
import PDFKit
@testable import LazyPDFMac
import LazyPDFApp
import LazyPDFKit

// Stands in for the PagePaginator tests of windows/LazyPDF.App.Tests/PrintFlowTests.cs: the operation is built for a
// fixture and not run, since running it opens a print panel.

@MainActor
final class MacSystemPrintTests: XCTestCase {
    private func operation(_ bytes: [UInt8], _ password: String? = nil, title: String = "a.pdf") throws -> NSPrintOperation? {
        MacSystemPrint.operation(try PdfEditSession.open(bytes, password: password), password: password, title: title, info: NSPrintInfo())
    }

    func test_theOperationIsBuiltForTheDocumentsCurrentBytes() throws {
        let operation = try XCTUnwrap(try operation(try MacPdfs.text(pages: 3)))

        XCTAssertNotNil(operation.view)
    }

    func test_aBookletIsPrintedAsLandscapeSheets() throws {
        let session = try PdfEditSession.open(try MacPdfs.text(pages: 5))

        let laid = try XCTUnwrap(MacSystemPrint.operation(session, password: nil, title: "a.pdf", layout: PrintLayout(booklet: true), info: NSPrintInfo()))

        XCTAssertEqual(laid.operation.printInfo.orientation, .landscape)
        XCTAssertEqual(laid.dropped, 0)
    }

    func test_theSheetsAreMadeForThePaperInTheInfoGiven() throws {
        let session = try PdfEditSession.open(try MacPdfs.text(pages: 4))
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 842, height: 1191)

        let laid = try XCTUnwrap(MacSystemPrint.operation(session, password: nil, title: "a.pdf", layout: PrintLayout(booklet: true), info: info))
        let paper = laid.operation.printInfo.paperSize

        XCTAssertEqual(max(paper.width, paper.height), 1191, accuracy: 1)
    }

    func test_oddPagesAreAFileOfTheirOwn() throws {
        let session = try PdfEditSession.open(try MacPdfs.text(pages: 4))

        XCTAssertNotNil(MacSystemPrint.operation(session, password: nil, title: "a.pdf", layout: PrintLayout(parity: .odd), info: NSPrintInfo()))
    }

    func test_noPagesLeftIsNotPrinted() throws {
        let session = try PdfEditSession.open(try MacPdfs.text(pages: 1))

        XCTAssertNil(MacSystemPrint.operation(session, password: nil, title: "a.pdf", layout: PrintLayout(parity: .even), info: NSPrintInfo()))
    }

    func test_theJobCarriesTheDocumentsTitle() throws {
        let operation = try XCTUnwrap(try operation(try MacPdfs.text(), title: "Report.pdf"))

        XCTAssertEqual(operation.jobTitle, "Report.pdf")
    }

    func test_aLockedFileIsPrintedOnceItIsOpened() throws {
        let locked = try MacPdfs.fixture("locked.pdf")

        XCTAssertNotNil(try operation(locked, "secret"))
    }

    func test_anAes256FileIsPrintedThroughTheEnginesCopy() throws {
        let bytes = try MacPdfs.fixture("crypt-aes256.pdf")

        XCTAssertNotNil(try operation(bytes, "secret"))
    }

    func test_aFileForRecipientsIsPrintedThroughTheEnginesCopy() throws {
        let alice = try MacCertificatesTests.identity("Alice")
        let session = try PdfEditSession.open(try MacCertificatesTests.encrypted(for: alice), certificate: try XCTUnwrap(PdfCertificate(alice)))

        XCTAssertNotNil(MacSystemPrint.operation(session, password: nil, title: "a.pdf", info: NSPrintInfo()))
    }

    func test_aPageOfUserUnitTwoIsPrintedAtTwiceTheSize() throws {
        let session = try PdfEditSession.open(MacPdfs.square(unit: 2), password: nil)

        let document = try XCTUnwrap(MacSystemPrint.document(session, nil))

        let box = try XCTUnwrap(document.page(at: 0)).bounds(for: .cropBox)
        XCTAssertEqual(box.width, 200, accuracy: 0.5)
        XCTAssertEqual(box.height, 200, accuracy: 0.5)
    }

    func test_aPageOfUserUnitOneKeepsItsSize() throws {
        let session = try PdfEditSession.open(MacPdfs.square(), password: nil)

        let box = try XCTUnwrap(MacSystemPrint.document(session, nil)?.page(at: 0)).bounds(for: .cropBox)

        XCTAssertEqual(box.width, 100, accuracy: 0.5)
    }
}
#endif
