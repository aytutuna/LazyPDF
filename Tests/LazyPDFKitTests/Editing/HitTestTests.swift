import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/HitTestTests.cs: the same cases.

final class HitTestTests: XCTestCase {
    private func open() throws -> (PageEditor, PdfEditSession) {
        let session = try EditKit.session(
            "0.8 g 50 50 200 100 re f\n" +
            "BT /F1 12 Tf 60 100 Td 0 g (Label) Tj ET\n" +
            "q 40 40 -40 40 400 400 cm 0 0 1 rg 0 0 1 1 re f Q\n" +
            "1 0 0 RG 3 w 300 100 m 500 100 l S\n" +
            "0 1 0 rg 450 200 m 550 200 l 500 300 l h f")
        return (try PageEditor(session, 0), session)
    }

    func test_theTopmostObjectUnderThePointIsFound() throws {
        let (editor, _) = try open()
        XCTAssertEqual(try editor.objects.count, 5)
        XCTAssertTrue(try editor.hitTest(70, 103) is TextObject)
        // The grey box is under the text; away from the text the box answers.
        XCTAssertEqual(try editor.hitTest(200, 70)?.id, 0)
        XCTAssertTrue(try editor.hitTest(200, 70) is PathObject)
        XCTAssertNil(try editor.hitTest(20, 20))
    }

    func test_aRotatedFillIsHitInsideTheTurnedSquareOnly() throws {
        let (editor, _) = try open()
        // The square is turned 45 degrees: its corners are at (400,400), (440,440), (400,480), (360,440).
        XCTAssertNotNil(try editor.hitTest(400, 440))
        XCTAssertNil(try editor.hitTest(365, 405))
    }

    func test_aStrokeIsHitNearItsLineAndATriangleInsideIt() throws {
        let (editor, _) = try open()
        XCTAssertTrue(try editor.hitTest(400, 101) is PathObject)
        XCTAssertNil(try editor.hitTest(400, 110))
        XCTAssertTrue(try editor.hitTest(500, 230) is PathObject)
        XCTAssertNil(try editor.hitTest(460, 280))
    }

    func test_aRectangleSelectsWhatTouchesOrWhatLiesInside() throws {
        let (editor, _) = try open()
        let rect = PdfRect(40, 40, 260, 160)
        XCTAssertEqual(try editor.select(rect).count, 2)
        XCTAssertEqual(try editor.select(rect, true).count, 2)
        _ = try assertSingle(try editor.select(PdfRect(0, 0, 100, 100), false).filter { $0 is TextObject })
        XCTAssertTrue(try editor.select(PdfRect(0, 0, 100, 100), true).isEmpty)
    }

    func test_objectsKnowTheirKindFormAndBounds() throws {
        let (editor, _) = try open()
        XCTAssertEqual(try editor.objects.map { $0.kind }, [.path, .text, .path, .path, .path])
        for o in try editor.objects { XCTAssertTrue(o.forms.isEmpty) }
        let text = try XCTUnwrap(try editor.objects[1] as? TextObject)
        XCTAssertEqual(text.text, "Label")
        XCTAssertEqual(text.size, 12, accuracy: 0.005)
        XCTAssertEqual(text.font?.name, "Helvetica")
        XCTAssertEqual(text.color, RgbColor(0, 0, 0))
        XCTAssertEqual(text.bounds.left, 60, accuracy: 0.05)
    }

    func test_anEditorWhoseSessionLostItsPageThrowsOutOfRange() throws {
        let (_, session) = try open()
        try PageOperations.insertBlank(session.document, 1, 612, 792)
        XCTAssertTrue(try session.commit("Insert page"))
        let last = try PageEditor(session, 1)
        XCTAssertEqual(try last.objects.count, 0)
        XCTAssertTrue(try session.undo())
        XCTAssertThrowsError(try last.objects) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try last.text) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try last.hitTest(10, 10)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try last.select(PdfRect(0, 0, 100, 100))) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try last.addRectangle(PdfRect(10, 10, 50, 50), ShapeStyle(stroke: RgbColor(0, 0, 0)))) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try PageEditor(session, 1)) { XCTAssertTrue($0 is ArgumentException) }
    }
}
