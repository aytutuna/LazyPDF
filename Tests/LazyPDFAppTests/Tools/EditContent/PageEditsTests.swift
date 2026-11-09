import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/edit/PageEditsTests.cs: the edits of the Edit text and images panel, each a real call
// to the engine's page editor on a document in a tab.

@MainActor
final class PageEditsTests: XCTestCase {
    private func open(_ bytes: [UInt8]? = nil, password: String? = nil) throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(bytes ?? Pdfs.text(), password: password), renderer: FakeRenderer(), url: nil,
                    title: "t.pdf", password: password)
    }

    private func edits(_ tab: DocumentTab) -> PageEdits {
        PageEdits(tab, fonts: FakeFonts(), codec: FakeCodec())
    }

    private func pageText(_ tab: DocumentTab, _ page: Int = 0) throws -> String {
        try PageEditor(tab.session, page).text.text
    }

    private func objects(_ tab: DocumentTab) throws -> [PageObject] {
        try PageEditor(tab.session, 0).objects
    }

    // What the panel does: the copy is made off the document, then adopted by it.
    private func replaceAll(_ tab: DocumentTab, _ find: String, _ replacement: String, _ token: CancelToken = CancelToken()) async throws -> EditOutcome {
        let edits = edits(tab)
        let made = try await edits.replaceAll(tab.session.current, find, replacement, TextSearchOptions(), token)
        return try edits.adopt(made)
    }

    private func threeLines() throws -> [UInt8] {
        try PdfFromText.create("First line of the text.\nSecond line of the text.\nThird line of the text.", fonts: FakeFonts()).bytes
    }

    func test_typingOverALineChangesThePageAndShowsIt() throws {
        let tab = try open()
        var raised = 0
        tab.changed = { raised += 1 }
        let line = try XCTUnwrap((try objects(tab)[0] as? TextObject)?.lines.first)

        let outcome = try edits(tab).replaceLine(0, line, "Goodbye from the tests.")

        XCTAssertTrue(outcome.done)
        XCTAssertTrue(try pageText(tab).contains("Goodbye from the tests."))
        XCTAssertEqual(raised, 1)
        XCTAssertEqual(tab.revision, 1)
        XCTAssertTrue(tab.isDirty)
    }

    func test_undoTakesTheTypedLineBack() throws {
        let tab = try open()
        let line = try XCTUnwrap((try objects(tab)[0] as? TextObject)?.lines.first)
        _ = try edits(tab).replaceLine(0, line, "Something else entirely.")

        try tab.undo()

        XCTAssertTrue(try pageText(tab).contains("Hello from the tests."))
    }

    func test_lettersNoFontHasAreRefusedWithTheEnginesReasonAndNothingIsCommitted() throws {
        let tab = try open()
        let line = try XCTUnwrap((try objects(tab)[0] as? TextObject)?.lines.first)

        let outcome = try edits(tab).replaceLine(0, line, "漢字")

        XCTAssertFalse(outcome.done)
        XCTAssertFalse(outcome.problem?.isEmpty ?? true)
        XCTAssertFalse(tab.session.canUndo)
        XCTAssertEqual(tab.revision, 0)
    }

    func test_aParagraphTakesMoreLinesAndSaysItGrew() throws {
        let tab = try open(try threeLines())
        let block = try XCTUnwrap(try objects(tab)[0] as? TextObject)

        let outcome = try edits(tab).replaceParagraph(0, block.id, "First line of the text. Second line of the text. Third line of the text. A fourth sentence that needs another line, and a fifth one that needs yet another line, then more.")

        XCTAssertTrue(outcome.done)
        XCTAssertNotNil(outcome.note)
        XCTAssertTrue(try pageText(tab).contains("fifth"))
    }

    func test_anObjectThatIsGoneIsReportedNotThrown() throws {
        let tab = try open()

        let outcome = try edits(tab).style(0, 999, TextStyleChange(size: 20))

        XCTAssertFalse(outcome.done)
        XCTAssertEqual(outcome.problem, EditingText.staleObject)
    }

    func test_aSizeChangeIsReadBackFromThePage() throws {
        let tab = try open()
        let block = try XCTUnwrap(try objects(tab)[0] as? TextObject)

        let outcome = try edits(tab).style(0, block.id, TextStyleChange(size: 24))

        XCTAssertTrue(outcome.done)
        XCTAssertEqual(try XCTUnwrap(try objects(tab)[0] as? TextObject).size, 24, accuracy: 0.1)
    }

    func test_aTextBoxIsAddedAndATooSmallOneSaysItOverflows() throws {
        let tab = try open()
        let edits = edits(tab)

        let fits = try edits.addTextBox(0, PdfRect(100, 400, 400, 500), "A new box", TextBoxStyle(family: "Arial", size: 12))
        let tight = try edits.addTextBox(0, PdfRect(100, 300, 160, 312), "Far too many words for such a small box", TextBoxStyle(family: "Arial", size: 12))

        XCTAssertTrue(fits.done)
        XCTAssertNil(fits.note)
        XCTAssertTrue(try pageText(tab).contains("A new box"))
        XCTAssertTrue(tight.done)
        XCTAssertNotNil(tight.note)
    }

    func test_aPictureIsAddedThroughTheCodecAndUnreadableBytesAreRefused() throws {
        let tab = try open()
        let edits = edits(tab)

        let bad = try edits.addImage(0, PdfRect(50, 400, 250, 500), [])
        let good = try edits.addImage(0, PdfRect(50, 400, 250, 500), [1, 2, 3])

        XCTAssertFalse(bad.done)
        XCTAssertEqual(bad.problem, EditingText.noImage)
        XCTAssertTrue(good.done)
        XCTAssertEqual(try objects(tab).filter { $0 is ImageObject }.count, 1)
    }

    func test_aPictureKeepsItsProportionsInsideTheBox() throws {
        let tab = try open()

        _ = try edits(tab).addImage(0, PdfRect(50, 400, 350, 500), [1])

        let image = try XCTUnwrap(try objects(tab).compactMap { $0 as? ImageObject }.first)
        XCTAssertEqual(image.bounds.width, 100, accuracy: 1)
        XCTAssertEqual(image.bounds.height, 100, accuracy: 1)
        XCTAssertEqual(image.bounds.left, 150, accuracy: 1)
    }

    func test_objectsAreMovedResizedTurnedAndDeletedAsOneStepEach() throws {
        let tab = try open()
        let edits = edits(tab)
        _ = try edits.addImage(0, PdfRect(100, 400, 200, 500), [1])
        let id = try XCTUnwrap(try objects(tab).first { $0 is ImageObject }).id
        let start = try objects(tab)[id].bounds

        XCTAssertTrue(try edits.move(0, [id], 30, -20).done)
        let moved = try objects(tab)[id].bounds
        XCTAssertEqual(moved.left, start.left + 30, accuracy: 1)
        XCTAssertEqual(moved.bottom, start.bottom - 20, accuracy: 1)

        XCTAssertTrue(try edits.resize(0, [id], PdfRect(moved.left, moved.bottom, moved.left + 200, moved.bottom + 50)).done)
        XCTAssertEqual(try objects(tab)[id].bounds.width, 200, accuracy: 1)

        XCTAssertTrue(try edits.rotate(0, [id], 90).done)
        XCTAssertEqual(try objects(tab)[id].bounds.width, 50, accuracy: 1)

        XCTAssertTrue(try edits.delete(0, [id]).done)
        XCTAssertTrue(try objects(tab).filter { $0 is ImageObject }.isEmpty)

        var steps = 0
        while try tab.undo() { steps += 1 }
        XCTAssertEqual(steps, 5)
    }

    func test_opacityOrderAndShapeColoursReachThePage() throws {
        let tab = try open()
        let edits = edits(tab)
        let page = try PageEditor(tab.session, 0, FakeFonts())
        _ = try page.addRectangle(PdfRect(100, 400, 200, 500), ShapeStyle(stroke: RgbColor(0, 0, 255), fill: RgbColor(255, 0, 0), width: 2))
        let id = try XCTUnwrap(try objects(tab).first { $0 is PathObject }).id

        XCTAssertTrue(try edits.pathStyle(0, [id], fill: RgbColor(0, 255, 0), stroke: nil, width: 5).done)
        let path = try XCTUnwrap(try objects(tab)[id] as? PathObject)
        XCTAssertEqual(path.fillColor, RgbColor(0, 255, 0))
        XCTAssertEqual(path.lineWidth, 5, accuracy: 0.1)

        XCTAssertTrue(try edits.opacity(0, [id], 0.5).done)
        XCTAssertEqual(try XCTUnwrap(try objects(tab)[id] as? PathObject).opacity, 0.5, accuracy: 0.01)
    }

    func test_replaceAllChangesEveryPageInOneStep() async throws {
        let tab = try open(Pdfs.text(3, "The tests say hello."))

        let outcome = try await replaceAll(tab, "hello", "goodbye")

        XCTAssertTrue(outcome.done)
        XCTAssertEqual(outcome.note, "Replaced 3 times.")
        for p in 0..<3 { XCTAssertTrue(try pageText(tab, p).contains("goodbye")) }
        XCTAssertTrue(try tab.session.undo())
        XCTAssertFalse(tab.session.canUndo)
    }

    func test_replaceAllWithNothingFoundSaysSoAndLeavesTheFileClean() async throws {
        let tab = try open()

        let outcome = try await replaceAll(tab, "absent", "x")

        XCTAssertFalse(outcome.done)
        XCTAssertEqual(outcome.problem, "Nothing found to replace.")
        XCTAssertFalse(tab.isDirty)
    }

    func test_aCancelledReplaceAllLeavesNoHalfEditInTheDocument() async throws {
        let tab = try open(Pdfs.text(3, "The tests say hello."))
        let cancelled = CancelToken()
        cancelled.cancel()

        do {
            _ = try await replaceAll(tab, "hello", "goodbye", cancelled)
            XCTFail("The job should have been cancelled.")
        } catch is CancellationError {}

        XCTAssertFalse(tab.document.hasChanges)
        XCTAssertFalse(tab.isDirty)
    }

    func test_replaceAllReadsAFileThatNeedsAPassword() async throws {
        let plain = try PdfDocument.open(Pdfs.text(2, "The tests say hello."))
        let security = PdfSecurity.create(userPassword: "pw", ownerPassword: "owner", permissions: .all, strength: .aes256,
                                          firstId: plain.firstId ?? [])
        let tab = try open(try plain.saveRewrite(PdfSaveOptions(security: security)), password: "pw")

        let outcome = try await replaceAll(tab, "hello", "goodbye")

        XCTAssertTrue(outcome.done)
        XCTAssertTrue(try pageText(tab, 1).contains("goodbye"))
    }

    func test_aLinkIsAddedChangedAndRemoved() throws {
        let tab = try open()
        let edits = edits(tab)
        let area = PdfRect(50, 700, 200, 720)

        XCTAssertTrue(try edits.setLink(0, area, UriAction("https://example.com"), nil).done)
        let link = try XCTUnwrap(edits.links(0).first)
        XCTAssertEqual(edits.links(0).count, 1)
        XCTAssertEqual(link.uri, "https://example.com")

        XCTAssertTrue(try edits.setLink(0, area, GoToAction(PdfDestination(0)), link).done)
        XCTAssertEqual(edits.links(0).count, 1)
        let changed = try XCTUnwrap(edits.links(0).first)
        XCTAssertNil(changed.uri)
        XCTAssertEqual(changed.destination?.pageIndex, 0)

        XCTAssertTrue(try edits.removeLink(0, changed).done)
        XCTAssertTrue(edits.links(0).isEmpty)
    }

    func test_aWebAddressGetsItsSchemeWhenItHasNone() {
        let cases = [
            ("example.com", "https://example.com"),
            ("mailto:me@example.com", "mailto:me@example.com"),
            (" https://example.com/a ", "https://example.com/a"),
            ("example.com:8080/a", "https://example.com:8080/a"),
        ]
        for (typed, expected) in cases {
            XCTAssertEqual((PageEdits.target(toPage: false, typed, 3) as? UriAction)?.uri, expected, typed)
        }
    }

    func test_aTargetThatIsNeitherAnAddressNorAPageOfTheFileIsRefused() {
        let cases: [(Bool, String)] = [(false, ""), (false, "two words"), (true, "0"), (true, "4"), (true, "x")]
        for (toPage, typed) in cases {
            XCTAssertNil(PageEdits.target(toPage: toPage, typed, 3), typed)
        }
    }

    func test_aPageNumberIsCountedFromOne() throws {
        let target = try XCTUnwrap(PageEdits.target(toPage: true, "3", 3) as? GoToAction)

        XCTAssertEqual(target.destination.pageIndex, 2)
    }
}
