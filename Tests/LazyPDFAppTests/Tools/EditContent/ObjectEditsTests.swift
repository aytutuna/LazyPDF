import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/edit/ObjectEditsTests.cs: pictures, shapes, links, the copy a replace-all makes, and
// the permission check, on real documents. The permission check is ChangeGate.refusal, which the Stamps and EditContent tools
// share (Windows has a copy of it in each).

@MainActor
final class ObjectEditsTests: XCTestCase {
    private let directLink = "/Annots [<< /Type /Annot /Subtype /Link /Rect [50 700 200 720] /Border [0 0 2] /C [1 0 0] /A << /S /URI /URI (https://old.example) >> >>]"

    private func open(_ bytes: [UInt8]? = nil) throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(bytes ?? EditPdf.make("")), renderer: FakeRenderer(), url: nil, title: "t.pdf")
    }

    private func edits(_ tab: DocumentTab) -> ContentEdits {
        ContentEdits(tab, fonts: FakeFonts(), codec: FakeCodec())
    }

    private func objects(_ tab: DocumentTab) throws -> [PageObject] {
        try PageEditor(tab.session, 0).objects
    }

    private func picture(_ tab: DocumentTab) throws -> ImageObject {
        try XCTUnwrap(try objects(tab).compactMap { $0 as? ImageObject }.first)
    }

    private func withPicture(_ pageKeys: String = "") throws -> DocumentTab {
        let tab = try open(EditPdf.make("", pageKeys: pageKeys))
        _ = try edits(tab).addImage(0, PdfRect(100, 500, 200, 600), [1])
        return tab
    }

    func test_aCroppedPictureMovesWithItsCrop() throws {
        let tab = try withPicture()
        let edits = edits(tab)
        XCTAssertTrue(try edits.crop(0, try picture(tab).id, PdfRect(100, 500, 150, 550)).done)
        let cropped = try picture(tab).bounds
        XCTAssertEqual(cropped.width, 50, accuracy: 1)

        XCTAssertTrue(try edits.move(0, [try picture(tab).id], 200, 0).done)

        let moved = try picture(tab).bounds
        XCTAssertEqual(moved.width, 50, accuracy: 1)
        XCTAssertEqual(moved.left, cropped.left + 200, accuracy: 1)
    }

    func test_aCroppedPictureResizesAndTurnsWithItsCrop() throws {
        let tab = try withPicture()
        let edits = edits(tab)
        _ = try edits.crop(0, try picture(tab).id, PdfRect(100, 500, 150, 550))
        let cropped = try picture(tab).bounds

        XCTAssertTrue(try edits.resize(0, [try picture(tab).id], PdfRect(cropped.left, cropped.bottom, cropped.left + 100, cropped.bottom + 100)).done)
        XCTAssertEqual(try picture(tab).bounds.width, 100, accuracy: 1)

        XCTAssertTrue(try edits.rotate(0, [try picture(tab).id], 90).done)
        XCTAssertEqual(try picture(tab).bounds.height, 100, accuracy: 1)
    }

    // Where the picture's own right and up point on the page as shown.
    private func directions(_ tab: DocumentTab) throws -> (right: (x: Double, y: Double), up: (x: Double, y: Double)) {
        let g = PageGeometry(tab.document.pages[0]).matrix
        let m = try picture(tab).placement
        return ((g.a * m.a + g.c * m.b, g.b * m.a + g.d * m.b), (g.a * m.c + g.c * m.d, g.b * m.c + g.d * m.d))
    }

    func test_flippingAcrossMirrorsLeftToRightOnThePageAsShown() throws {
        for pageKeys in ["", "/Rotate 90", "/Rotate 180", "/Rotate 270"] {
            let tab = try withPicture(pageKeys)
            let (right, up) = try directions(tab)

            XCTAssertTrue(try edits(tab).flip(0, [try picture(tab).id], acrossScreen: true, viewRotation: 0).done, pageKeys)

            let (rightAfter, upAfter) = try directions(tab)
            XCTAssertEqual(rightAfter.x, -right.x, accuracy: 1, pageKeys)
            XCTAssertEqual(rightAfter.y, right.y, accuracy: 1, pageKeys)
            XCTAssertEqual(upAfter.x, up.x, accuracy: 1, pageKeys)
            XCTAssertEqual(upAfter.y, up.y, accuracy: 1, pageKeys)
        }
    }

    func test_flippingDownMirrorsTopToBottomOnATurnedPage() throws {
        let tab = try withPicture("/Rotate 90")
        let (right, up) = try directions(tab)

        XCTAssertTrue(try edits(tab).flip(0, [try picture(tab).id], acrossScreen: false, viewRotation: 0).done)

        let (rightAfter, upAfter) = try directions(tab)
        XCTAssertEqual(rightAfter.x, right.x, accuracy: 1)
        XCTAssertEqual(upAfter.y, -up.y, accuracy: 1)
    }

    func test_theViewTurnedAQuarterSwapsTheFlipToo() throws {
        let tab = try withPicture()
        let (right, up) = try directions(tab)

        XCTAssertTrue(try edits(tab).flip(0, [try picture(tab).id], acrossScreen: true, viewRotation: 90).done)

        let (rightAfter, upAfter) = try directions(tab)
        XCTAssertEqual(rightAfter.x, right.x, accuracy: 1)
        XCTAssertEqual(upAfter.y, -up.y, accuracy: 1)
    }

    func test_aFillOnAShapeWithoutOneIsRefusedInsteadOfChangingNothing() throws {
        let tab = try open()
        _ = try PageEditor(tab.session, 0, FakeFonts()).addEllipse(PdfRect(100, 400, 200, 500), ShapeStyle(stroke: RgbColor(255, 0, 0), fill: nil, width: 2))
        let id = try XCTUnwrap(try objects(tab).first { $0 is PathObject }).id

        let fill = try edits(tab).pathStyle(0, [id], fill: RgbColor(0, 0, 255), stroke: nil, width: nil)
        let line = try edits(tab).pathStyle(0, [id], fill: nil, stroke: RgbColor(0, 0, 255), width: nil)

        XCTAssertFalse(fill.done)
        XCTAssertNotNil(fill.problem)
        XCTAssertTrue(line.done)
        XCTAssertEqual(try XCTUnwrap(try objects(tab)[id] as? PathObject).strokeColor, RgbColor(0, 0, 255))
    }

    func test_aLinkGivenDirectlyOnThePageIsChangedWhereItIs() throws {
        let tab = try open(EditPdf.make("", pageKeys: directLink))
        let edits = edits(tab)
        let link = try XCTUnwrap(edits.links(0).first)
        XCTAssertEqual(edits.links(0).count, 1)
        XCTAssertNil(link.reference)

        XCTAssertTrue(try edits.setLink(0, link.rect, UriAction("https://new.example"), link).done)

        XCTAssertEqual(edits.links(0).count, 1)
        XCTAssertEqual(edits.links(0).first?.uri, "https://new.example")
        let annots = try XCTUnwrap(tab.document.array(tab.document.pages[0].dictionary, "Annots"))
        XCTAssertEqual(annots.items.count, 1)
        let annot = try XCTUnwrap(annots.items[0] as? PdfDictionary)
        XCTAssertTrue(annot.containsKey("Border"))
        XCTAssertTrue(annot.containsKey("C"))
    }

    func test_aLinkGivenDirectlyOnThePageCanBeRemoved() throws {
        let tab = try open(EditPdf.make("", pageKeys: directLink))
        let edits = edits(tab)

        XCTAssertTrue(try edits.removeLink(0, try XCTUnwrap(edits.links(0).first)).done)

        XCTAssertTrue(edits.links(0).isEmpty)
    }

    func test_changingALinkKeepsItsAnnotation() throws {
        let tab = try open()
        let edits = edits(tab)
        let area = PdfRect(50, 700, 200, 720)
        _ = try edits.setLink(0, area, UriAction("https://one.example"), nil)
        let link = try XCTUnwrap(edits.links(0).first)

        _ = try edits.setLink(0, area, GoToAction(PdfDestination(0)), link)

        XCTAssertEqual(edits.links(0).count, 1)
        XCTAssertEqual(edits.links(0).first?.reference, link.reference)
        XCTAssertEqual(tab.session.undoLabel, "Change link")
    }

    func test_aReplaceAllMadeOnACopyIsOneStepOnTheDocument() async throws {
        let tab = try open(Pdfs.text(2, "The tests say hello."))
        let edits = edits(tab)
        let made = try await edits.replaceAll(tab.session.current, "hello", "goodbye", TextSearchOptions(), CancelToken())
        XCTAssertFalse(tab.isDirty)

        let outcome = try edits.adopt(made)

        XCTAssertTrue(outcome.done)
        XCTAssertEqual(tab.session.undoLabel, "Replace text")
        XCTAssertTrue(try tab.session.undo())
        XCTAssertFalse(tab.session.canUndo)
    }

    func test_aReplaceAllIsRefusedWhenTheDocumentMovedOnWhileItRan() async throws {
        let tab = try open(Pdfs.text(2, "The tests say hello."))
        let edits = edits(tab)
        let made = try await edits.replaceAll(tab.session.current, "hello", "goodbye", TextSearchOptions(), CancelToken())
        try Pdfs.retitle(tab.session, "Changed meanwhile")
        try tab.commit("Title")

        let outcome = try edits.adopt(made)

        XCTAssertFalse(outcome.done)
        XCTAssertNotNil(outcome.problem)
        XCTAssertEqual(tab.session.undoLabel, "Title")
    }

    func test_aReplaceAllIsRefusedWhenAnUndoWentBackWhileItRan() async throws {
        let tab = try open(Pdfs.text(2, "The tests say hello."))
        try Pdfs.retitle(tab.session, "First")
        try tab.commit("Title")
        let edits = edits(tab)
        let made = try await edits.replaceAll(tab.session.current, "hello", "goodbye", TextSearchOptions(), CancelToken())
        try tab.undo()

        let outcome = try edits.adopt(made)

        XCTAssertFalse(outcome.done)
        XCTAssertFalse(tab.session.canUndo)
    }

    func test_aCancelledReplaceAllNeverTouchesTheDocument() async throws {
        let tab = try open(Pdfs.text(3, "The tests say hello."))
        let cancelled = CancelToken()
        cancelled.cancel()
        let bytes = tab.session.current

        do {
            _ = try await edits(tab).replaceAll(bytes, "hello", "goodbye", TextSearchOptions(), cancelled)
            XCTFail("The job should have been cancelled.")
        } catch is CancellationError {}

        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(tab.session.current, bytes)
    }

    func test_aFileThatForbidsChangesIsRefusedUntilItIsOpenedAsOwner() throws {
        let locked = try PdfDocument.open(try Pdfs.restricted(.print))
        let owner = try PdfDocument.open(try Pdfs.restricted(.print), password: "owner")

        XCTAssertNotNil(ChangeGate.refusal(locked))
        XCTAssertNil(ChangeGate.refusal(owner))
        XCTAssertNil(ChangeGate.refusal(try PdfDocument.open(Pdfs.text())))
    }

    func test_aFileThatAllowsModifyingIsNotRefused() throws {
        XCTAssertNil(ChangeGate.refusal(try PdfDocument.open(try Pdfs.restricted([.print, .modify]))))
    }
}
