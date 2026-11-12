import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/edit/EditSurfaceTests.cs: the geometry of the selection handles, and the look the typed
// text takes from the run it replaces. The reach of a handle is a fingertip's here (24 screen points, never over a third of
// the box) where Windows has 8 pixels, so the zoom test uses a point further from the handle. With no font the typed text is
// Helvetica, which every Apple platform has, where Windows says Arial.

@MainActor
final class EditSurfaceTests: XCTestCase {
    private let box = ViewRect(100, 100, 200, 100)

    func test_everyHandleIsFoundWhereItIsDrawn() async {
        let places: [(handle: Int, x: Double, y: Double)] = [
            (0, 100, 100), (1, 200, 100), (2, 300, 100), (3, 300, 150), (4, 300, 200), (5, 200, 200), (6, 100, 200), (7, 100, 150),
        ]
        for place in places {
            XCTAssertEqual(EditSurface.handleIndex(at: ViewPoint(place.x + 1, place.y - 1), of: box, scale: 1), place.handle)
        }
    }

    func test_thePointerAwayFromTheHandlesFindsNone() async {
        XCTAssertEqual(EditSurface.handleIndex(at: ViewPoint(200, 150), of: box, scale: 1), -1)
    }

    func test_theReachOfAHandleShrinksWithTheZoom() async {
        XCTAssertEqual(EditSurface.handleIndex(at: ViewPoint(120, 100), of: box, scale: 2), -1)
        XCTAssertEqual(EditSurface.handleIndex(at: ViewPoint(120, 100), of: box, scale: 1), 0)
    }

    func test_aSmallBoxCanStillBeGrabbedByItsMiddle() async {
        let small = ViewRect(100, 100, 30, 30)

        XCTAssertEqual(EditSurface.handleIndex(at: ViewPoint(115, 115), of: small, scale: 1), -1)
    }

    func test_draggingTheRightSideWidensTheBoxAndHoldsTheLeft() async {
        let resized = EditSurface.resize(box, 3, ViewPoint(350, 999), square: false)

        XCTAssertEqual(resized, ViewRect(100, 100, 250, 100))
    }

    func test_aCornerKeepsTheProportionsUnlessShiftIsDown() async {
        let square = EditSurface.resize(box, 4, ViewPoint(500, 150), square: true)
        let free = EditSurface.resize(box, 4, ViewPoint(500, 150), square: false)

        XCTAssertEqual(square, ViewRect(100, 100, 400, 200))
        XCTAssertEqual(free, ViewRect(100, 100, 400, 50))
    }

    func test_aDragPastTheOppositeSideLeavesASliverNotAFlippedBox() async {
        let resized = EditSurface.resize(box, 0, ViewPoint(900, 900), square: false)

        XCTAssertTrue(resized.width > 0 && resized.height > 0)
        XCTAssertEqual(resized.right, box.right)
        XCTAssertEqual(resized.bottom, box.bottom)
    }

    func test_withNoFontTheTypedTextIsInHelvetica() async {
        XCTAssertEqual(EditorLook.familyOf(nil), "Helvetica")
        XCTAssertEqual(EditorLook.nameOf(nil), "")
    }

    func test_aFontTakesTheInstalledFamilyItsNameStarts() async throws {
        let tab = DocumentTab(session: try PdfEditSession.open(EditPdf.make(EditPdf.paragraph)), renderer: FakeRenderer(), url: nil, title: "t.pdf")
        let block = try XCTUnwrap(PageEditor(tab.session, 0).objects.first as? TextObject)

        XCTAssertEqual(EditorLook.familyOf(block.font, installed: ["Helvetica Neue", "Helvetica", "Hel"]), "Helvetica")
        XCTAssertEqual(EditorLook.nameOf(block.font, installed: ["Courier"]), block.font?.name)
        XCTAssertEqual(EditorLook.familyOf(block.font), "Helvetica")
    }

    func test_everyColourOfThePaletteHasANameAndTheyAreDistinct() async {
        let colors = Palette.colors

        XCTAssertTrue(colors.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertEqual(colors.count, Set(colors.map { [$0.color.r, $0.color.g, $0.color.b] }).count)
    }
}
