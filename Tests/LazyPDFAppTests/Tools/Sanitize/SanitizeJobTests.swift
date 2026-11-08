import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/optimize/SanitizeJobTests.cs: Clean for sharing, the rows a scan makes, the options the
// ticks stand for and a run on a real file.

final class SanitizeJobTests: XCTestCase {
    private func titled() throws -> [UInt8] {
        let session = try PdfEditSession.open(Pdfs.text(2))
        try Pdfs.retitle(session, "Salary figures")
        try session.commit("Title")
        return session.current
    }

    private var all: Set<SanitizeItem> { Set(SanitizeItem.allCases) }

    func test_theScanFindsTheTitleAsMetadata() throws {
        let hits = try SanitizeJob.scan(try titled(), password: nil, certificate: nil)

        XCTAssertTrue(hits.contains { $0.item == .metadata })
    }

    func test_onlyTheRemovableItemsCanBeSwitchedAndInvisibleTextStartsOff() {
        let rows = Dictionary(uniqueKeysWithValues: SanitizeItem.allCases.map { ($0, SanitizeRow(SanitizeFinding($0, 1))) })

        XCTAssertTrue(rows[.comments]!.canTick)
        XCTAssertTrue(rows[.comments]!.isChecked)
        XCTAssertFalse(rows[.hiddenText]!.canTick)
        XCTAssertFalse(rows[.hiddenText]!.isChecked)
        XCTAssertFalse(rows[.previousVersions]!.canTick)
        XCTAssertTrue(rows[.previousVersions]!.isChecked)
        XCTAssertTrue(rows[.invisibleText]!.canTick)
        XCTAssertFalse(rows[.invisibleText]!.isChecked)
    }

    func test_theTicksBecomeOptions() {
        let options = SanitizeJob.options([.comments, .invisibleText])

        XCTAssertTrue(options.comments)
        XCTAssertTrue(options.invisibleText)
        XCTAssertFalse(options.javaScript)
        XCTAssertFalse(options.metadata)
    }

    func test_aRunTakesOutWhatWasTickedAndSaysSo() throws {
        let result = try SanitizeJob.run(try titled(), password: nil, certificate: nil, ticked: all, token: CancelToken())

        XCTAssertTrue(result.removed.contains { $0.item == .metadata })
        XCTAssertTrue(SanitizeJob.list(result.removed).contains(OptimizeText.itemName(.metadata)))
        let reopened = try PdfDocument.open(result.bytes)
        XCTAssertEqual(reopened.pages.count, 2)
        XCTAssertNotEqual(DocumentMetadata.read(reopened).title, "Salary figures")
    }

    func test_anItemLeftUntickedStaysInTheFile() throws {
        var ticked = all
        ticked.remove(.metadata)

        let result = try SanitizeJob.run(try titled(), password: nil, certificate: nil, ticked: ticked, token: CancelToken())

        XCTAssertTrue(result.kept.contains { $0.item == .metadata })
        let reopened = try PdfDocument.open(result.bytes)
        XCTAssertEqual(DocumentMetadata.read(reopened).title, "Salary figures")
    }

    func test_aRunThatWasCancelledGivesNothing() throws {
        let token = CancelToken()
        token.cancel()

        XCTAssertThrowsError(try SanitizeJob.run(try titled(), password: nil, certificate: nil, ticked: all, token: token)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
