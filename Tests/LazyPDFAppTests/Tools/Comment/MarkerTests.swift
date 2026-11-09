import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/comment/MarkerTests.cs: what the panel asks of the engine, marks made from page
// points, found again under the pointer, changed and removed.

@MainActor
final class MarkerTests: XCTestCase {
    private let drag = [pt(60, 80), pt(260, 140)]

    func test_eachToolMakesItsKindOfMark() throws {
        let cases: [(MarkTool, AnnotationType)] = [
            (.rectangle, .square), (.oval, .circle), (.line, .line), (.arrow, .line), (.textBox, .freeText), (.note, .text),
        ]
        for (tool, type) in cases {
            let f = try CommentFixture()

            let made = try f.marker.add(tool, 0, drag, red, "Look here")

            XCTAssertEqual(made.type, type)
            XCTAssertTrue(made.hasAppearance)
            XCTAssertEqual(made.title, "Ana")
            XCTAssertEqual(f.marks().count, 1)
        }
    }

    func test_toolsThatTakeManyPointsUseAllOfThem() throws {
        let points = [pt(50, 50), pt(150, 60), pt(140, 160), pt(40, 150)]
        let cases: [(MarkTool, AnnotationType)] = [(.polygon, .polygon), (.cloud, .polygon), (.pencil, .ink)]
        for (tool, type) in cases {
            let f = try CommentFixture()

            let made = try f.marker.add(tool, 0, points, red)

            XCTAssertEqual(made.type, type)
            XCTAssertEqual(made.vertices.count, tool == .pencil ? 0 : 8)
            if tool == .cloud { XCTAssertGreaterThan(made.cloud, 0) }
            if tool == .pencil { XCTAssertEqual(made.inkList[0].count, 8) }
        }
    }

    func test_aDraggedBoxComesBackWhereItWasDrawn() throws {
        let f = try CommentFixture()

        let made = try f.marker.add(.rectangle, 0, drag, red)

        let box = f.marker.box(of: made)
        XCTAssertEqual(box.left, 60, accuracy: 0.5)
        XCTAssertEqual(box.top, 80, accuracy: 0.5)
        XCTAssertEqual(box.width, 200, accuracy: 0.5)
        XCTAssertEqual(box.height, 60, accuracy: 0.5)
        XCTAssertEqual(made.rect.bottom, f.geometry.height - 140, accuracy: 0.5)
    }

    func test_aBoxDrawnOnATurnedPageComesBackWhereItWasDrawn() throws {
        let f = try CommentFixture()
        f.document.pages[0].dictionary["Rotate"] = PdfNumber(90)

        let made = try f.marker.add(.rectangle, 0, drag, red)

        let box = f.marker.box(of: made)
        XCTAssertEqual(box.left, 60, accuracy: 0.5)
        XCTAssertEqual(box.top, 80, accuracy: 0.5)
        XCTAssertEqual(box.width, 200, accuracy: 0.5)
    }

    func test_aCalloutSitsAtTheEndOfTheDragAndPointsBack() throws {
        let f = try CommentFixture()
        let dragged = [pt(100, 100), pt(300, 200)]

        let made = try f.marker.add(.callout, 0, dragged, red, "See the chart")

        XCTAssertEqual(made.type, .freeText)
        XCTAssertEqual(made.callout.count, 4)
        let (x, y) = f.geometry.toUser(100, 100)
        XCTAssertEqual(made.callout[0], x, accuracy: 0.5)
        XCTAssertEqual(made.callout[1], y, accuracy: 0.5)
        let box = Marker.box(for: .callout, dragged)
        XCTAssertEqual(box.x + box.width / 2, 300, accuracy: 0.01)
        XCTAssertEqual(box.y + box.height / 2, 200, accuracy: 0.01)
    }

    func test_textTheFontsCannotDrawIsRefusedAndLeavesNoMark() throws {
        let f = try CommentFixture()

        XCTAssertThrowsError(try f.marker.add(.textBox, 0, drag, red, "Çalışma ğ")) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, AnnotationText.noFont)
        }

        XCTAssertTrue(f.marks().isEmpty)
    }

    func test_aToolThatDoesNotDrawByItselfIsRefused() throws {
        let f = try CommentFixture()

        XCTAssertThrowsError(try f.marker.add(.eraser, 0, drag, red)) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_aSelectedRunBecomesOneMarkupWithItsQuadsInAcrobatOrder() throws {
        let f = try CommentFixture()
        let quad = TextQuad(100, 700, 180, 700, 180, 712, 100, 712)
        let run = SelectedRun(page: 0, range: TextRange(0, 0), text: "Hello", quads: [quad])

        let count = try f.marker.markup(.highlight, [run], .default)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(f.marks().count, 1)
        let made = try XCTUnwrap(f.marks().first)
        XCTAssertEqual(made.type, .highlight)
        XCTAssertEqual(made.quadPoints, [100, 712, 180, 712, 100, 700, 180, 700])
    }

    func test_aRunWithNoQuadsMarksNothing() throws {
        let f = try CommentFixture()

        let count = try f.marker.markup(.underline, [SelectedRun(page: 0, range: TextRange(0, 0), text: "", quads: [])], .default)

        XCTAssertEqual(count, 0)
        XCTAssertTrue(f.marks().isEmpty)
    }

    func test_aStampAndAnAttachmentLandWhereTheyWereClicked() throws {
        let f = try CommentFixture()

        let stamp = try f.marker.addStamp(0, pt(200, 300), "Approved", .default)
        let file = try f.marker.addAttachment(0, pt(400, 100), "data.csv", [1, 2, 3])

        XCTAssertEqual(stamp.type, .stamp)
        XCTAssertEqual(f.marker.box(of: stamp).x + Marker.stampWidth / 2, 200, accuracy: 0.5)
        XCTAssertEqual(file.type, .fileAttachment)
        XCTAssertEqual(f.marker.box(of: file).x, 400, accuracy: 0.5)
    }

    func test_thePointerFindsTheTopmostMarkUnderIt() throws {
        let f = try CommentFixture()
        try f.marker.add(.rectangle, 0, [pt(50, 50), pt(250, 250)], red)
        let top = try f.marker.add(.oval, 0, [pt(100, 100), pt(200, 200)], red)

        XCTAssertEqual(f.marker.at(0, pt(100, 150), 4)?.reference?.number, top.reference?.number)
        XCTAssertEqual(f.marker.at(0, pt(50, 150), 4)?.type, .square)
        XCTAssertNil(f.marker.at(0, pt(400, 400), 4))
    }

    func test_aLineIsFoundNearItsStrokeAndNotInTheEmptyCornerOfItsBox() throws {
        let f = try CommentFixture()
        try f.marker.add(.line, 0, [pt(100, 100), pt(300, 300)], red)

        XCTAssertNotNil(f.marker.at(0, pt(200, 201), 4))
        XCTAssertNil(f.marker.at(0, pt(300, 100), 4))
    }

    func test_anInkStrokeIsFoundNearItsPoints() throws {
        let f = try CommentFixture()
        try f.marker.add(.pencil, 0, [pt(100, 100), pt(200, 100), pt(200, 200)], red)

        XCTAssertNotNil(f.marker.at(0, pt(150, 101), 4))
        XCTAssertNil(f.marker.at(0, pt(100, 200), 4))
    }

    func test_repliesAreNotPickedUpOnThePage() throws {
        let f = try CommentFixture()
        let note = try f.marker.add(.note, 0, [pt(100, 100)], red, "Question")
        let reply = try PdfComments.reply(f.document, note, "Answer", "Can", DateTimeOffset(2026, 11, 5, 9, 0, 0))

        XCTAssertFalse(Marker.selectable(reply))
        XCTAssertTrue(Marker.selectable(note))
    }

    func test_movingShiftsTheMarkByTheDragInPageSpace() throws {
        let f = try CommentFixture()
        let made = try f.marker.add(.rectangle, 0, drag, red)

        let moved = try f.marker.move(made, 10, 20)

        let box = f.marker.box(of: moved)
        XCTAssertEqual(box.left, 70, accuracy: 0.5)
        XCTAssertEqual(box.top, 100, accuracy: 0.5)
        XCTAssertEqual(box.width, 200, accuracy: 0.5)
    }

    func test_resizingFitsTheMarkIntoTheNewBox() throws {
        let f = try CommentFixture()
        let made = try f.marker.add(.rectangle, 0, drag, red)

        let resized = try f.marker.resize(made, ViewRect(50, 70, 300, 120))

        let box = f.marker.box(of: resized)
        XCTAssertEqual(box.left, 50, accuracy: 0.5)
        XCTAssertEqual(box.width, 300, accuracy: 0.5)
        XCTAssertEqual(box.height, 120, accuracy: 0.5)
    }

    func test_colourWidthAndOpacityChangeTheMarkAndKeepItsLook() throws {
        let f = try CommentFixture()
        let made = try f.marker.add(.rectangle, 0, drag, red)

        let blue = try f.marker.recolor(made, [0, 0, 1])
        let wide = try f.marker.setWidth(blue, 6)
        let faint = try f.marker.setOpacity(wide, 0.5)

        XCTAssertEqual(faint.color, [0, 0, 1])
        XCTAssertEqual(faint.border.width, 6)
        XCTAssertEqual(faint.opacity, 0.5)
        XCTAssertTrue(faint.hasAppearance)
    }

    func test_editedTextIsKeptAndANoteDoesNotNeedAFont() throws {
        let f = try CommentFixture()
        let note = try f.marker.add(.note, 0, [pt(100, 100)], red, "First")

        let edited = try f.marker.setText(note, "Second, with ğ")

        XCTAssertEqual(edited.contents, "Second, with ğ")
    }

    func test_deletingAMarkRemovesItsRepliesToo() throws {
        let f = try CommentFixture()
        let note = try f.marker.add(.note, 0, [pt(100, 100)], red, "Question")
        _ = try PdfComments.reply(f.document, note, "Answer", "Can", DateTimeOffset(2026, 11, 5, 9, 0, 0))
        XCTAssertEqual(f.marks().count, 2)

        XCTAssertTrue(f.marker.delete(f.marks()[0]))

        XCTAssertTrue(f.marks().isEmpty)
    }

    func test_findingAMarkAgainAfterACommitUsesItsObjectNumber() throws {
        let f = try CommentFixture()
        let made = try f.marker.add(.rectangle, 0, drag, red)
        let number = try XCTUnwrap(made.reference?.number)

        try f.tab.commit("Rectangle")

        XCTAssertEqual(f.marker.find(0, number)?.type, .square)
        XCTAssertNil(f.marker.find(0, number + 100))
        XCTAssertNil(f.marker.find(5, number))
    }

    func test_aMarkIsOneUndoStepAndSurvivesAReread() throws {
        let f = try CommentFixture()
        try f.marker.add(.rectangle, 0, drag, red)

        XCTAssertTrue(try f.tab.commit("Rectangle"))
        let reread = try PdfDocument.open(f.tab.session.current)
        XCTAssertEqual(PdfAnnotations.read(reread, reread.pages[0]).count, 1)

        XCTAssertTrue(try f.tab.undo())
        XCTAssertTrue(f.marks().isEmpty)
    }
}
