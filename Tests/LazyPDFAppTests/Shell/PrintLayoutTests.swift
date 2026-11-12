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

    func test_aNoteIsGivenOnlyForWhatWasLeftOff() {
        XCTAssertNil(PrintLayout.droppedNote(0))
        XCTAssertEqual(PrintLayout.droppedNote(1), "1 link or note without a picture was left off the sheets.")
    }
}
