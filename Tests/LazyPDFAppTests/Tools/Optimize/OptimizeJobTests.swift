import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/optimize/OptimizeJobTests.cs: Make smaller, the audit rows, the options each choice
// stands for and a run on real files. AFileThatRestrictsItsPermissionsNeedsTheOwner is the ToolDocuments.needsOwner check;
// ThePercentSavedIsRounded keeps its three cases in one test.

final class OptimizeJobTests: XCTestCase {
    private let balanced = OptimizeChoice(.balanced, .standard, grayscale: false, fastWebView: false)

    private func run(_ file: [UInt8], password: String? = nil, _ choice: OptimizeChoice, token: CancelToken = CancelToken()) throws -> OptimizeOutcome {
        try OptimizeJob.run(file, password: password, certificate: nil, choice: choice, codec: FakeCodec(), token: token)
    }

    func test_theAuditListsTheBiggestKindFirstAndAddsUpToTheFile() throws {
        let audit = try OptimizeJob.audit(Pdfs.text(5), password: nil, certificate: nil)

        let rows = AuditRow.of(audit)

        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.bytes > 0 })
        XCTAssertEqual(rows.map(\.bytes), rows.map(\.bytes).sorted(by: >))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 1.0, accuracy: 1e-6)
    }

    func test_thePresetsGiveTheCoreOnes() {
        XCTAssertEqual(OptimizeChoice(.small, .standard, grayscale: false, fastWebView: false).options(nil).imageDpi, 96)
        XCTAssertEqual(balanced.options(nil).imageDpi, 150)
        XCTAssertEqual(OptimizeChoice(.high, .standard, grayscale: false, fastWebView: false).options(nil).imageDpi, 300)
    }

    func test_customSettingsAndGrayscaleReachTheOptions() {
        let custom = CustomSize(imageDpi: 200, jpegQuality: 60, trimFonts: false, blackWhite: false, dropAppData: false, dropPrivateKeys: true)

        let options = OptimizeChoice(.custom, custom, grayscale: true, fastWebView: false).options(nil)

        XCTAssertEqual(options.imageDpi, 200)
        XCTAssertEqual(options.imageDpiAbove, 300)
        XCTAssertEqual(options.jpegQuality, 60)
        XCTAssertEqual(options.bilevelTolerance, -1)
        XCTAssertFalse(options.subsetFonts)
        XCTAssertFalse(options.stripPieceInfo)
        XCTAssertTrue(options.stripPrivateData)
        XCTAssertTrue(options.grayscale)
    }

    func test_aRunGivesAFileThatReopensWithTheSamePages() throws {
        let outcome = try run(Pdfs.text(3), balanced)

        let reopened = try PdfDocument.open(outcome.bytes)
        XCTAssertEqual(reopened.pages.count, 3)
        XCTAssertEqual(outcome.bytes.count, outcome.sizeAfter)
        XCTAssertFalse(reopened.isLinearized)
    }

    func test_fastWebViewLinearizesTheResult() throws {
        var choice = balanced
        choice.fastWebView = true

        let outcome = try run(Pdfs.text(3), choice)

        let reopened = try PdfDocument.open(outcome.bytes)
        XCTAssertTrue(reopened.isLinearized)
        XCTAssertEqual(reopened.pages.count, 3)
        XCTAssertEqual(outcome.bytes.count, outcome.sizeAfter)
    }

    func test_aPasswordFileComesOutLocked() throws {
        let document = try PdfDocument.open(Pdfs.text())
        let security = PdfSecurity.create(userPassword: "open", ownerPassword: "owner", permissions: .all, strength: .aes256,
                                          firstId: document.firstId ?? [])
        let locked = try document.saveRewrite(PdfSaveOptions(security: security))
        var choice = balanced
        choice.fastWebView = true

        let outcome = try run(locked, password: "owner", choice)

        XCTAssertThrowsError(try PdfDocument.open(outcome.bytes))
        XCTAssertTrue(try PdfDocument.open(outcome.bytes, password: "open").isEncrypted)
    }

    func test_aCancelledRunGivesNothing() {
        let token = CancelToken()
        token.cancel()

        XCTAssertThrowsError(try run(Pdfs.text(), balanced, token: token)) { XCTAssertTrue($0 is CancellationError) }
    }

    func test_thePercentSavedIsRounded() {
        XCTAssertEqual(SizeText.percent(1000, 250), 75)
        XCTAssertEqual(SizeText.percent(1000, 1000), 0)
        XCTAssertEqual(SizeText.percent(0, 0), 0)
    }

    func test_anAes128FileKeepsTheIdItsKeysCameFrom() throws {
        let id = (1...16).map { UInt8($0) }
        let source = try PdfDocument.open(Pdfs.text())
        let security = PdfSecurity.create(userPassword: "open", ownerPassword: "owner", permissions: .all, strength: .aes128, firstId: id)
        let locked = try source.saveRewrite(PdfSaveOptions(security: security, documentId: id))

        for web in [false, true] {
            var choice = balanced
            choice.fastWebView = web
            let outcome = try run(locked, password: "open", choice)

            XCTAssertTrue(try PdfDocument.open(outcome.bytes, password: "open").isEncrypted)
            XCTAssertEqual(try PdfDocument.open(outcome.bytes, password: "owner").pages.count, 1)
        }
    }

    func test_aFileThatRestrictsItsPermissionsNeedsTheOwner() throws {
        let restricted = try PdfDocument.open(Pdfs.restricted(.print))
        let open = try PdfDocument.open(Pdfs.restricted(.print), password: "owner")
        let plain = try PdfDocument.open(Pdfs.text())

        XCTAssertTrue(ToolDocuments.needsOwner(restricted))
        XCTAssertFalse(ToolDocuments.needsOwner(open))
        XCTAssertFalse(ToolDocuments.needsOwner(plain))
    }

    func test_theSizesAreWrittenInTheLargestUnitThatFits() {
        XCTAssertEqual(SizeText.of(900), "900 bytes")
        XCTAssertEqual(SizeText.of(1536), "1.5 KB")
        XCTAssertEqual(SizeText.of(3 * 1_048_576), "3 MB")
    }
}
