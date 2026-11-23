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
        XCTAssertEqual(PrintLayout(parity: .even).pages(count: 4), [1, 3])
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

    func test_reverseAloneIsNotPlain() {
        let layout = PrintLayout(reverse: true)

        XCTAssertFalse(layout.isPlain)
        XCTAssertEqual(layout.pages(count: 3), [2, 1, 0])
    }

    func test_aLayoutLeavesTheRangeToTheSides() {
        let layout = PrintLayout(perSheet: 2, parity: .even, reverse: true, range: "2-6")

        XCTAssertEqual(layout.pages(count: 8), [1, 2, 3, 4, 5])
    }

    func test_oddSidesOfABookletAreTheFronts() {
        let layout = PrintLayout(booklet: true, parity: .odd)

        XCTAssertEqual(layout.sideCount(8), 4)
        XCTAssertEqual(layout.sheetsToPrint(4), [0, 2])
        XCTAssertEqual(PrintLayout(booklet: true, parity: .even).sheetsToPrint(4), [1, 3])
    }

    func test_anEvenRunOfAnOddCountEndsWithABlankOrStartsWithOneWhenReversed() {
        XCTAssertEqual(PrintLayout(perSheet: 2, parity: .even).sheetsToPrint(5), [1, 3, -1])
        XCTAssertEqual(PrintLayout(perSheet: 2, parity: .even, reverse: true).sheetsToPrint(5), [-1, 3, 1])
        XCTAssertEqual(PrintLayout(perSheet: 2, parity: .odd).sheetsToPrint(5), [0, 2, 4])
        XCTAssertEqual(PrintLayout(perSheet: 2, parity: .even).sheetsToPrint(1), [])
        XCTAssertEqual(PrintLayout(parity: .even).pages(count: 5), [1, 3, -1])
        XCTAssertEqual(PrintLayout(parity: .even, reverse: true).pages(count: 5), [-1, 3, 1])
        XCTAssertEqual(PrintLayout(parity: .odd).pages(count: 5), [0, 2, 4])
    }

    func test_aBookletNeverGetsABlank() {
        for count in 1...12 {
            let layout = PrintLayout(booklet: true, parity: .even)
            XCTAssertFalse(layout.sheetsToPrint(layout.sideCount(count)).contains(-1), "\(count) pages")
        }
    }

    func test_theSideCountMatchesWhatImposeMakes() throws {
        for count in 1...20 {
            let source = try PdfDocument.open(Pdfs.text(count))
            for layout in [PrintLayout(booklet: true)] + PrintLayout.perSheetChoices.dropFirst().map({ PrintLayout(perSheet: $0) }) {
                let made = try PageOperations.impose(source, Array(0..<count), layout.options(sheetWidth: 612, sheetHeight: 792)).sheets
                XCTAssertEqual(layout.sideCount(count), made, "\(count) pages, \(layout)")
            }
        }
        XCTAssertEqual(PrintLayout(booklet: true).sideCount(0), 0)
    }

    func test_nothingIsLeftOfOneSideWhenEvenIsAsked() {
        XCTAssertTrue(PrintLayout(perSheet: 2, parity: .even).isEmpty(count: 2))
        XCTAssertFalse(PrintLayout(perSheet: 2, parity: .even).isEmpty(count: 3))
        XCTAssertTrue(PrintLayout(parity: .even).isEmpty(count: 1))
        XCTAssertTrue(PrintLayout(parity: .odd, range: "2").isEmpty(count: 3))
    }

    func test_aGapTooWideForTheSheetIsRefused() {
        XCTAssertNil(PrintLayout(perSheet: 4, gap: 10).validate(sheetWidth: 612, sheetHeight: 792))
        XCTAssertNotNil(PrintLayout(perSheet: 4, gap: 300).validate(sheetWidth: 612, sheetHeight: 792))
        XCTAssertNotNil(PrintLayout(booklet: true, gap: 270).validate(sheetWidth: 612, sheetHeight: 792))
        XCTAssertNil(PrintLayout(gap: 900).validate(sheetWidth: 612, sheetHeight: 792))
    }

    func test_onlyThePerSheetBookletGapAndBorderAreRemembered() {
        var preferences = AppPreferences()
        PrintLayout(perSheet: 4, booklet: true, parity: .odd, reverse: true, rightToLeft: true, gap: 20, border: true).remember(in: &preferences)

        let layout = PrintLayout.remembered(preferences)

        XCTAssertEqual(layout, PrintLayout(perSheet: 4, booklet: true, gap: 20, border: true))
    }

    func test_aPlainPrintKeepsTheRememberedGapAndAWrongValueFallsBack() {
        var preferences = AppPreferences()
        preferences.printGap = 12
        PrintLayout(gap: 0).remember(in: &preferences)
        XCTAssertEqual(preferences.printGap, 12)

        preferences.printPerSheet = 5
        preferences.printGap = 500
        XCTAssertEqual(PrintLayout.remembered(preferences).perSheet, 1)
        XCTAssertEqual(PrintLayout.remembered(preferences).gap, PrintLayout.maxGap)
    }

    func test_theRememberedChoicesSurviveTheSettingsFile() throws {
        var preferences = AppPreferences()
        PrintLayout(perSheet: 9, gap: 5, border: true).remember(in: &preferences)

        let back = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))

        XCTAssertEqual(PrintLayout.remembered(back), PrintLayout(perSheet: 9, gap: 5, border: true))
    }

    func test_rightToLeftGapAndBorderGoToTheEngine() {
        let options = PrintLayout(perSheet: 4, rightToLeft: true, gap: 8, border: true).options(sheetWidth: 612, sheetHeight: 792)

        XCTAssertTrue(options.rightToLeft)
        XCTAssertEqual(options.gap, 8)
        XCTAssertTrue(options.border)
    }

    func test_oddSidesOfABookletAreAFileOfTheFrontsOnly() throws {
        let source = try PdfDocument.open(Pdfs.text(8))

        let fronts = try PrintLayout(booklet: true, parity: .odd).file(source, sheetWidth: 612, sheetHeight: 792)
        let backs = try PrintLayout(booklet: true, parity: .even, reverse: true).file(source, sheetWidth: 612, sheetHeight: 792)

        XCTAssertEqual(fronts.count, 2)
        XCTAssertEqual(try PdfDocument.open(fronts.bytes).pages.count, 2)
        XCTAssertEqual(backs.count, 2)
        XCTAssertEqual(try PdfDocument.open(backs.bytes).pages.count, 2)
    }

    func test_theSidesLeftOutAreNotInTheFile() throws {
        let source = try PdfDocument.open(Pdfs.text(60, String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)))

        let all = try PrintLayout(perSheet: 2).file(source, sheetWidth: 612, sheetHeight: 792)
        let some = try PrintLayout(perSheet: 2, parity: .odd).file(source, sheetWidth: 612, sheetHeight: 792)

        XCTAssertEqual(some.count, 15)
        XCTAssertLessThan(some.bytes.count, all.bytes.count * 6 / 10)
    }

    func test_anEvenRunOfAnOddCountHasABlankPageAtTheEnd() throws {
        let source = try PdfDocument.open(Pdfs.text(5))

        let plain = try PrintLayout(parity: .even).file(source, sheetWidth: 612, sheetHeight: 792)
        let reversed = try PrintLayout(perSheet: 2, parity: .even, reverse: true).file(source, sheetWidth: 612, sheetHeight: 792)

        let plainPages = try PdfDocument.open(plain.bytes).pages
        XCTAssertEqual(plain.count, 3)
        XCTAssertEqual(plainPages.count, 3)
        XCTAssertTrue(plainPages[2].contents().isEmpty)
        XCTAssertFalse(plainPages[0].contents().isEmpty)
        XCTAssertEqual(plainPages[2].cropBox.width, plainPages[1].cropBox.width, accuracy: 1e-3)
        let reversedPages = try PdfDocument.open(reversed.bytes).pages
        XCTAssertEqual(reversed.count, 2)
        XCTAssertEqual(reversedPages.count, 2)
        XCTAssertTrue(reversedPages[0].contents().isEmpty)
        XCTAssertEqual(reversedPages[0].cropBox.width, 612, accuracy: 1e-3)
    }

    func test_nothingLeftToPrintIsAnErrorNotAnEmptyFile() throws {
        let source = try PdfDocument.open(Pdfs.text(2))

        XCTAssertThrowsError(try PrintLayout(perSheet: 2, parity: .even).file(source, sheetWidth: 612, sheetHeight: 792))
        XCTAssertThrowsError(try PrintLayout(parity: .even, range: "1").file(source, sheetWidth: 612, sheetHeight: 792))
    }

    func test_aCancelWhileTheJobRunsReturnsOnlyAfterTheJobHasEnded() async throws {
        let token = CancelToken()
        let ended = Flag()
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            token.cancel()
        }

        do {
            _ = try await PrintLayout.inBackground(token: token) { () -> Int in
                defer { Thread.sleep(forTimeInterval: 0.1); ended.set() }
                while true {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }

        XCTAssertTrue(ended.isSet)
    }

    func test_aJobThatEndsBeforeTheCancelStillGivesItsResultOrTheCancel() async throws {
        let value = try await PrintLayout.inBackground(token: CancelToken()) { 7 }

        XCTAssertEqual(value, 7)
    }

    func test_thePlainSummaryCountsPagesAndCallsOddAndEvenPagesNotFrontsAndBacks() {
        XCTAssertEqual(PrintLayout().summary(documentPages: 8), "8 pages.")
        XCTAssertEqual(PrintLayout().summary(documentPages: 1), "1 page.")
        XCTAssertEqual(PrintLayout(reverse: true, range: "3-5").summary(documentPages: 8), "3 pages. In reverse order.")
        XCTAssertEqual(PrintLayout(parity: .odd, range: "2-5").summary(documentPages: 8), "4 pages. Odd pages: 2 of 4.")
        XCTAssertEqual(PrintLayout(parity: .even, range: "2-5").summary(documentPages: 8), "4 pages. Even pages: 2 of 4.")
    }

    func test_aLayoutSummaryCountsSidesAndPapers() {
        XCTAssertEqual(PrintLayout(booklet: true).summary(documentPages: 8), "8 pages: 4 sides on 2 pieces of paper.")
        XCTAssertEqual(PrintLayout(perSheet: 2).summary(documentPages: 1), "1 page: 1 side on 1 piece of paper.")
        XCTAssertEqual(PrintLayout(booklet: true, parity: .odd).summary(documentPages: 8),
                       "8 pages: 4 sides on 2 pieces of paper. Odd sides (fronts): 2 of 4.")
        XCTAssertEqual(PrintLayout(perSheet: 4, parity: .even, range: "2-7").summary(documentPages: 20),
                       "6 pages: 2 sides on 1 piece of paper. Even sides (backs): 1 of 2.")
    }

    func test_theSummaryNamesTheBlankOfAnOddCountAndSaysWhenNothingIsLeft() {
        XCTAssertEqual(PrintLayout(perSheet: 2, parity: .even).summary(documentPages: 5),
                       "5 pages: 3 sides on 2 pieces of paper. Even sides (backs): 1 of 3. 3 sides: a blank is added at the end of the even run so each back meets its front.")
        XCTAssertTrue(PrintLayout(perSheet: 2, parity: .even, reverse: true).summary(documentPages: 5).contains("at the start of the even run"))
        XCTAssertFalse(PrintLayout(perSheet: 2, parity: .odd).summary(documentPages: 5).contains("blank"))
        XCTAssertEqual(PrintLayout(parity: .even).summary(documentPages: 1), "1 page. No sides are left to print.")
    }

    func test_aNoteIsGivenOnlyForWhatWasLeftOff() {
        XCTAssertNil(PrintLayout.droppedNote(0))
        XCTAssertEqual(PrintLayout.droppedNote(1), "1 link or note without a picture was left off the sheets.")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
