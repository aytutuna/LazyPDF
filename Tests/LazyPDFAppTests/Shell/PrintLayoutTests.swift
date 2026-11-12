import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PrintLayoutTests.cs, and adds the file the system sheets print.

final class PrintLayoutTests: XCTestCase {
    func test_thePlainLayoutChangesNothing() {
        let layout = PrintLayout()

        XCTAssertTrue(layout.isPlain)
        XCTAssertFalse(layout.imposes)
        XCTAssertEqual(layout.pages(count: 4), [0, 1, 2, 3])
    }

    func test_oddAndEvenAreByPageNumber() {
        XCTAssertEqual(PrintLayout(parity: .odd).pages(count: 5), [0, 2, 4])
        XCTAssertEqual(PrintLayout(parity: .even).pages(count: 5), [1, 3])
    }

    func test_theRangeIsTakenBeforeOddOrEven() {
        XCTAssertEqual(PrintLayout(parity: .even, range: "3-6").pages(count: 8), [3, 5])
        XCTAssertEqual(PrintLayout(parity: .odd, range: "3-5").pages(count: 9), [2, 4])
        XCTAssertEqual(PrintLayout(range: "2, 4-").pages(count: 5), [1, 3, 4])
    }

    func test_aTypedRangeIsNotPlainAndAWrongOneIsReported() {
        XCTAssertFalse(PrintLayout(range: "1-2").isPlain)
        XCTAssertNil(PrintLayout().rangeError(count: 3))
        XCTAssertNil(PrintLayout(range: "1-3").rangeError(count: 3))
        XCTAssertNotNil(PrintLayout(range: "9").rangeError(count: 3))
    }

    func test_oddOrEvenAloneDoesNotImpose() {
        let layout = PrintLayout(parity: .odd)

        XCTAssertFalse(layout.isPlain)
        XCTAssertFalse(layout.imposes)
    }

    func test_severalPagesPerSheetImpose() {
        let layout = PrintLayout(perSheet: 16)
        let options = layout.options(sheetWidth: 612, sheetHeight: 792)

        XCTAssertTrue(layout.imposes)
        XCTAssertEqual(options.mode, .nUp)
        XCTAssertEqual(options.perSheet, 16)
        XCTAssertEqual(options.sheetWidth, 612)
        XCTAssertEqual(options.sheetHeight, 792)
    }

    func test_aBookletWinsOverPagesPerSheet() {
        let layout = PrintLayout(perSheet: 4, booklet: true)

        XCTAssertTrue(layout.imposes)
        XCTAssertEqual(layout.options(sheetWidth: 612, sheetHeight: 792).mode, .booklet)
    }

    func test_theSheetsAreASavedFileOfTheRightCount() throws {
        let source = try PdfDocument.open(Pdfs.text(5))

        let sheets = try PrintLayout(perSheet: 2).file(source, sheetWidth: 612, sheetHeight: 792)

        XCTAssertEqual(sheets.count, 3)
        XCTAssertEqual(try PdfDocument.open(sheets.bytes).pages.count, 3)
    }

    func test_aBookletPadsToAMultipleOfFourPagesTwoToASheet() throws {
        let source = try PdfDocument.open(Pdfs.text(5))

        let sheets = try PrintLayout(booklet: true).file(source, sheetWidth: 612, sheetHeight: 792)

        XCTAssertEqual(sheets.count, 4)
        let box = try PdfDocument.open(sheets.bytes).pages[0].cropBox
        XCTAssertGreaterThan(box.width, box.height)
    }

    func test_oddPagesAloneArePrintedAsAFileOfThem() throws {
        let source = try PdfDocument.open(Pdfs.text(5))

        let sheets = try PrintLayout(parity: .odd).file(source, sheetWidth: 612, sheetHeight: 792)

        XCTAssertEqual(sheets.count, 3)
        XCTAssertEqual(try PdfDocument.open(sheets.bytes).pages.count, 3)
    }

    func test_theSheetsMadeInTheBackgroundAreTheSameFile() async throws {
        let source = try PdfDocument.open(Pdfs.text(5))
        let layout = PrintLayout(booklet: true)

        let sheets = try await layout.fileInBackground(source, sheetWidth: 612, sheetHeight: 792, token: CancelToken())

        XCTAssertEqual(sheets.count, 4)
        XCTAssertEqual(try PdfDocument.open(sheets.bytes).pages.count, 4)
    }

    func test_aCanceledTokenEndsTheWaitWithCancellation() async throws {
        let source = try PdfDocument.open(Pdfs.text(5))
        let token = CancelToken()
        token.cancel()

        do {
            _ = try await PrintLayout(booklet: true).fileInBackground(source, sheetWidth: 612, sheetHeight: 792, token: token)
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aNoteIsGivenOnlyForWhatWasLeftOff() {
        XCTAssertNil(PrintLayout.droppedNote(0))
        XCTAssertEqual(PrintLayout.droppedNote(1), "1 link or note without a picture was left off the sheets.")
    }
}
