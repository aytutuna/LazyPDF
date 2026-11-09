import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/redact/RedactJobTests.cs: what the Redact tool asks of the engine, finding, applying with
// and without flattening, and what it says afterwards. "TheCopyOpensAsANewFileThatHasToBeNamed" is kept with a view model. The
// font of the digit test is the system's (Core Text), as in the Windows test; it runs where there is one.

final class RedactJobTests: XCTestCase {
    private static let line = "Write to ann@example.com today."

    // Draws blank pages of the size the page has at that resolution, which is all the engine checks before it uses the picture.
    private final class BlankPages: PageRenderer {
        let file: [UInt8]

        init(_ file: [UInt8]) {
            self.file = file
        }

        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
            guard let document = try? PdfDocument.open(file) else { return nil }
            let page = PageGeometry(document.pages[pageIndex])
            let width = Int((page.width * dpi / 72).rounded()), height = Int((page.height * dpi / 72).rounded())
            return PdfRgbaImage(width, height, [UInt8](repeating: 255, count: width * height * 4))
        }
    }

    private let plain = RedactSettings(cover: Cover.all[0], overlayText: nil, flattenAll: false)

    private func textOf(_ pdf: [UInt8], _ page: Int = 0) throws -> String {
        TextCache(try PdfDocument.open(pdf)).get(page).text
    }

    private func findAddresses(_ pdf: [UInt8]) throws -> [MarkItem] {
        let document = try RedactJob.open(pdf, password: nil, certificate: nil)
        return try RedactJob.find(document, DataKind.all.first { $0.kind == .email }!).items
    }

    private func apply(_ pdf: [UInt8], _ marks: [MarkItem], _ settings: RedactSettings) throws -> RedactionResult {
        try RedactJob.apply(pdf, password: nil, certificate: nil, marks: marks.map(\.mark), settings: settings, renderer: BlankPages(pdf),
                            fonts: FakeFonts(), images: FakeCodec())
    }

    func test_aKindOfDataIsFoundOnEveryPage() throws {
        let found = try findAddresses(Pdfs.text(2, Self.line))

        XCTAssertEqual(found.map(\.page), [0, 1])
        XCTAssertTrue(found.allSatisfy { $0.label == "ann@example.com" })
    }

    func test_aWordIsFoundWholeOrInsideAnotherWord() throws {
        let document = try RedactJob.open(Pdfs.text(1, Self.line), password: nil, certificate: nil)

        let inside = try RedactJob.find(document, words: "to", matchCase: false, wholeWord: false).items
        let whole = try RedactJob.find(document, words: "to", matchCase: false, wholeWord: true).items
        let wrongCase = try RedactJob.find(document, words: "WRITE", matchCase: true, wholeWord: true).items

        XCTAssertEqual(inside.count, 2)
        XCTAssertEqual(whole.count, 1)
        XCTAssertTrue(wrongCase.isEmpty)
    }

    func test_aLongLabelIsClippedToOneLine() {
        let label = RedactJob.clip("one\ntwo   three " + String(repeating: "x", count: 80))

        XCTAssertTrue(label.hasPrefix("one two three x"))
        XCTAssertEqual(label.count, 40)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func test_whatIsMarkedIsGoneFromTheCopyAndTheCheckPasses() throws {
        let pdf = Pdfs.text(2, Self.line)
        let original = pdf

        let result = try apply(pdf, findAddresses(pdf), plain)

        XCTAssertFalse(try textOf(result.bytes, 0).contains("example"))
        XCTAssertFalse(try textOf(result.bytes, 1).contains("example"))
        XCTAssertTrue(try textOf(result.bytes).contains("Write to"))
        XCTAssertTrue(result.verification.isClean)
        XCTAssertEqual(original, pdf)
        XCTAssertTrue(result.report.flattened.isEmpty)
        let summary = RedactSummary.of(result)
        XCTAssertTrue(summary.clean)
        XCTAssertEqual(summary.problems, "")
        XCTAssertTrue(summary.report.contains("Page 1: removed"))
    }

    func test_aBoxOverTextTakesTheTextUnderIt() throws {
        let pdf = Pdfs.text(1, Self.line)
        let document = try PdfDocument.open(pdf)
        let page = TextCache(document).get(0)
        let geometry = PageGeometry(document.pages[0])
        let quad = page.quads(TextRange(0, 5))[0]
        let top = geometry.toDisplay(quad.bounds.left - 1, quad.bounds.top + 1)
        let bottom = geometry.toDisplay(quad.bounds.right + 1, quad.bounds.bottom - 1)
        let box = MarkShapes.box(0, geometry, from: ViewPoint(top.x, top.y), to: ViewPoint(bottom.x, bottom.y))

        let result = try apply(pdf, [MarkItem(box, "Box")], plain)

        XCTAssertTrue(try textOf(result.bytes).trimmingCharacters(in: .whitespaces).hasPrefix("to"))
        XCTAssertFalse(try textOf(result.bytes).contains("Write"))
    }

    func test_everyMarkedPageCanBeMadeAPicture() throws {
        let pdf = Pdfs.text(3, Self.line)
        let marks = try findAddresses(pdf).filter { $0.page != 1 }

        let result = try apply(pdf, marks, RedactSettings(cover: plain.cover, overlayText: nil, flattenAll: true))

        XCTAssertEqual(result.report.flattened, [0, 2])
        XCTAssertEqual(try textOf(result.bytes, 0), "")
        XCTAssertTrue(try textOf(result.bytes, 1).contains("Page 2"))
        XCTAssertEqual(try textOf(result.bytes, 2), "")
        let summary = RedactSummary.of(result)
        XCTAssertTrue(summary.report.contains("Pages 1, 3 are now pictures"))
        XCTAssertFalse(summary.report.contains("Page 1 was turned into a picture"))
    }

    func test_textOnTheBoxesIsDrawnWithoutASystemFont() throws {
        let pdf = Pdfs.text(1, Self.line)

        let result = try apply(pdf, findAddresses(pdf), RedactSettings(cover: plain.cover, overlayText: " REMOVED ", flattenAll: false))

        XCTAssertTrue(try textOf(result.bytes).contains("REMOVED"))
        XCTAssertFalse(try textOf(result.bytes).contains("example"))
        XCTAssertTrue(result.verification.isClean)
    }

    func test_anOverlayWithNoFontForItIsSaidInOurWords() throws {
        let pdf = Pdfs.text(1, Self.line)
        let settings = RedactSettings(cover: plain.cover, overlayText: "编辑", flattenAll: false)
        let marks = try findAddresses(pdf)

        XCTAssertThrowsError(try apply(pdf, marks, settings)) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, RedactionText.noFont)
            let problem = RedactJob.failed(error)
            XCTAssertEqual(problem.title, "Not redacted")
            XCTAssertFalse(problem.text.contains(RedactionText.noFont))
        }
    }

    func test_aMarkOnAPageThatIsNotThereIsLeftOut() throws {
        let pdf = Pdfs.text(1, Self.line)

        let result = try apply(pdf, [MarkItem(RedactionMark.fromRect(5, PdfRect(0, 0, 50, 50)), "Box")], plain)

        XCTAssertTrue(result.report.pages.isEmpty)
        XCTAssertEqual(RedactSummary.of(result).report, RedactionText.nothingFound)
    }

    func test_theCopyOfAFileOpenedWithItsPasswordOpensWithoutOne() throws {
        let document = try PdfDocument.open(Pdfs.text(1, Self.line))
        let security = PdfSecurity.create(userPassword: "secret", ownerPassword: "owner", permissions: .print, strength: .aes256,
                                          firstId: [UInt8](repeating: 7, count: 16))
        let pdf = try document.saveRewrite(PdfSaveOptions(security: security))
        let opened = try RedactJob.open(pdf, password: "owner", certificate: nil)
        let marks = try RedactJob.find(opened, DataKind.all[0]).items

        let result = try RedactJob.apply(pdf, password: "owner", certificate: nil, marks: marks.map(\.mark), settings: plain,
                                         renderer: BlankPages(pdf), fonts: FakeFonts(), images: FakeCodec())

        XCTAssertFalse(try PdfDocument.open(result.bytes).isEncrypted)
        XCTAssertFalse(try textOf(result.bytes).contains("example"))
    }

    func test_aFileThatForbidsChangesIsRefusedAndSaidSo() throws {
        let pdf = try Pdfs.restricted(.print)
        let mark = RedactionMark.fromRect(0, PdfRect(0, 0, 100, 100))

        XCTAssertThrowsError(try RedactJob.apply(pdf, password: nil, certificate: nil, marks: [mark], settings: plain,
                                                 renderer: BlankPages(pdf), fonts: FakeFonts(), images: FakeCodec())) { error in
            XCTAssertTrue(error is PdfPermissionException)
            let problem = RedactJob.failed(error)
            XCTAssertEqual(problem.title, "Not redacted")
            XCTAssertTrue(problem.text.contains("Ask its owner"))
        }
    }

    #if canImport(CoreText)
    func test_aDigitOfAnotherScriptIsNotASocialSecurityNumber() throws {
        let pdf = try PdfFromText.create("١٢٣-٤٥-٦٧٨٩", fonts: CoreTextFontSource()).bytes
        let document = try RedactJob.open(pdf, password: nil, certificate: nil)

        let found = try RedactJob.find(document, DataKind.all.first { $0.kind == .usSocialSecurity }!)

        XCTAssertTrue(found.items.isEmpty)
    }
    #endif

    func test_pagesWithNoTextAreCountedSoThatNothingFoundIsNotTakenForClean() throws {
        let pdf = try PdfFromText.create("ann@example.commore", fonts: FakeFonts()).bytes
        let document = try RedactJob.open(pdf, password: nil, certificate: nil)

        let found = try RedactJob.find(document, DataKind.all[0])

        XCTAssertEqual(found.items.count, 1)
        XCTAssertEqual(found.pictures, 1)
    }

    func test_aFileThatForbidsChangesIsKnownBeforeAnythingIsMarked() throws {
        let restricted = try PdfDocument.open(Pdfs.restricted(.print))
        let owned = try PdfDocument.open(Pdfs.restricted(.print), password: "owner")
        let plain = try PdfDocument.open(Pdfs.text())

        XCTAssertTrue(RedactJob.refuses(restricted))
        XCTAssertFalse(RedactJob.refuses(owned))
        XCTAssertFalse(RedactJob.refuses(plain))
    }

    func test_anUnexpectedErrorIsNotShownInTheFrameworksWords() {
        struct Odd: Error, CustomStringConvertible {
            var description: String { "Sequence contains no elements" }
        }

        let problem = RedactJob.failed(Odd())

        XCTAssertFalse(problem.text.contains("Sequence"))
        XCTAssertTrue(problem.text.contains("The file was not changed"))
    }

    func test_adviceAfterAFailedCheckDoesNotSendYouBackToWhatWasAlreadyDone() {
        for (flattenedAll, expected) in [(false, "Flattening every marked page"), (true, "Read the problems below.")] {
            let report = RedactionReport([], [], 0, [])
            let result = RedactionResult([], report, RedactionVerification(["Page 3 could not be followed to its end, so it was not fully checked."]))

            let summary = RedactSummary.of(result, flattenedAll: flattenedAll)

            XCTAssertFalse(summary.clean)
            XCTAssertTrue(summary.advice.contains(expected))
            XCTAssertEqual(summary.advice.contains("Flattening"), !flattenedAll)
        }
    }

    func test_thePassedCardSaysWhatTheCheckDidNotLookAt() {
        let report = RedactionReport([], [], 0, [])

        let summary = RedactSummary.of(RedactionResult([], report, RedactionVerification([])))

        XCTAssertTrue(summary.clean)
        XCTAssertFalse(summary.advice.contains("left in the copy"))
        XCTAssertTrue(summary.notChecked.contains("not marked"))
    }

    @MainActor
    func test_theCopyOpensAsANewFileThatHasToBeNamed() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let bytes = tab.session.current
        let marks = try findAddresses(bytes)
        let result = try RedactJob.apply(bytes, password: tab.password, certificate: nil, marks: marks.map(\.mark), settings: plain,
                                         renderer: tab.renderer, fonts: FakeFonts(), images: FakeCodec())

        await f.vm.openNew(result.bytes, title: "a (redacted).pdf")

        XCTAssertEqual(f.vm.documents.count, 2)
        XCTAssertTrue(AppViewModel.needsName(try XCTUnwrap(f.vm.activeDocument)))
        XCTAssertFalse(tab.isDirty)
    }
}
