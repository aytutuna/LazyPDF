import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/PathEditTests.cs: the same cases, except that the PdfPig assertion of
// NewShapesArePaintedWhereAsked (four paths on the page) has no twin; the interpreter's four paths are asserted above it.

final class PathEditTests: XCTestCase {
    private let content =
        "1 0 0 rg 0 0 1 RG 3 w 100 100 200 100 re B\n" +
        "q 0 1 0 rg 300 300 m 400 300 l 400 400 l h f Q\n" +
        "q 0 0 50 50 re W n 0 g 5 w 10 10 m 90 90 l S Q"

    private func open() throws -> (PdfEditSession, PageEditor) {
        let session = try EditKit.session(content)
        return (session, PageEditor(session, 0))
    }

    private func paths(_ editor: PageEditor) -> [PathObject] { editor.objects.compactMap { $0 as? PathObject } }

    func test_pathsAreModelledWithTheirPaint() throws {
        let (_, editor) = try open()
        let found = paths(editor)
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found[0].fill && found[0].stroke)
        XCTAssertEqual(found[0].fillColor, RgbColor(255, 0, 0))
        XCTAssertEqual(found[0].strokeColor, RgbColor(0, 0, 255))
        XCTAssertEqual(found[0].lineWidth, 3)
        XCTAssertEqual(found[0].bounds, PdfRect(98.5, 98.5, 301.5, 201.5))
        XCTAssertFalse(found[1].stroke)
        XCTAssertEqual(found[1].fillColor, RgbColor(0, 255, 0))
        XCTAssertEqual(found[2].lineWidth, 5)
    }

    func test_moveAndScaleLeaveTheCoordinatesAlone() throws {
        let (session, editor) = try open()
        XCTAssertTrue(try editor.move([paths(editor)[0]], 50, 25).done)
        let moved = try EditPaint.paths(session)[0].path
        XCTAssertEqual(moved.bounds, PdfRect(150, 125, 350, 225))
        XCTAssertTrue(EditKit.latin(session).contains("100 100 200 100 re B"))

        editor.refresh()
        XCTAssertTrue(try editor.resize([paths(editor)[0]], PdfRect(100, 100, 200, 150)).done)
        let scaled = try EditPaint.paths(session)[0].path
        let ink = try XCTUnwrap(PageEditor(session, 0).objects.compactMap { $0 as? PathObject }.first).bounds
        XCTAssertEqual(ink.left, 100, accuracy: 0.5)
        XCTAssertEqual(ink.right, 200, accuracy: 0.5)
        XCTAssertEqual(ink.bottom, 100, accuracy: 0.5)
        XCTAssertEqual(ink.top, 150, accuracy: 0.5)
        XCTAssertTrue(scaled.bounds.width < 100)
    }

    func test_recolourAndLineWidthApplyToThatPathOnly() throws {
        let (session, editor) = try open()
        let result = try editor.setPathStyle([paths(editor)[0]], fill: RgbColor(255, 255, 0), stroke: RgbColor(0, 0, 0), lineWidth: 8)
        XCTAssertTrue(result.done)
        let seen = try EditPaint.paths(session)
        XCTAssertEqual(seen[0].fill, RgbColor(255, 255, 0))
        XCTAssertEqual(seen[0].stroke, RgbColor(0, 0, 0))
        XCTAssertEqual(seen[0].lineWidth, 8)
        XCTAssertEqual(seen[1].fill, RgbColor(0, 255, 0))
        XCTAssertEqual(seen[2].lineWidth, 5)
    }

    func test_aDeletedPathIsGoneAndThePageAroundItKeepsItsBytes() throws {
        let (session, editor) = try open()
        XCTAssertTrue(try editor.delete([paths(editor)[1]]).done)
        XCTAssertEqual(try EditPaint.paths(session).count, 2)
        let text = EditKit.latin(session)
        XCTAssertTrue(text.hasPrefix("1 0 0 rg 0 0 1 RG 3 w 100 100 200 100 re B\nq 0 1 0 rg "))
        XCTAssertTrue(text.hasSuffix(" Q\nq 0 0 50 50 re W n 0 g 5 w 10 10 m 90 90 l S Q"))
    }

    func test_aPathThatClipsStaysAClipWhenItIsDeletedAndCannotBeMoved() throws {
        let session = try EditKit.session("q 0 0 100 100 re W f 0 g 10 10 m 90 90 l S Q")
        let editor = PageEditor(session, 0)
        let clipping = paths(editor)[0]
        XCTAssertTrue(clipping.clips)
        let moved = try editor.move([clipping], 5, 5)
        XCTAssertFalse(moved.done)
        XCTAssertEqual(moved.skipped[0].reason, EditingText.clipPath)
        XCTAssertTrue(try editor.delete([clipping]).done)
        XCTAssertTrue(EditKit.latin(session).contains("0 0 100 100 re W n"))
        _ = try assertSingle(try EditPaint.paths(session))
    }

    func test_newShapesArePaintedWhereAsked() throws {
        let session = try EditKit.session("5 0 0 5 0 0 cm 1 0 0 rg 0 0 10 10 re f")
        let editor = PageEditor(session, 0)
        XCTAssertTrue(try editor.addLine(10, 10, 110, 60, ShapeStyle(stroke: RgbColor(0, 0, 255), width: 2)).done)
        XCTAssertTrue(try editor.addRectangle(PdfRect(200, 200, 260, 240), ShapeStyle(fill: RgbColor(0, 128, 0), opacity: 0.5)).done)
        XCTAssertTrue(try editor.addEllipse(PdfRect(300, 300, 400, 340), ShapeStyle(stroke: RgbColor(0, 0, 0), fill: RgbColor(255, 255, 0))).done)
        let seen = try EditPaint.paths(session)
        XCTAssertEqual(seen.count, 4)
        XCTAssertEqual(seen[1].path.bounds, PdfRect(10, 10, 110, 60))
        XCTAssertEqual(seen[1].lineWidth, 2)
        XCTAssertEqual(seen[1].stroke, RgbColor(0, 0, 255))
        XCTAssertEqual(seen[2].path.bounds, PdfRect(200, 200, 260, 240))
        XCTAssertEqual(seen[2].alpha, 0.5, accuracy: 0.0005)
        XCTAssertEqual(seen[2].fill, RgbColor(0, 128, 0))
        XCTAssertEqual(seen[3].path.bounds.left, 300, accuracy: 0.05)
        XCTAssertEqual(seen[3].path.bounds.right, 400, accuracy: 0.05)
        XCTAssertEqual(seen[3].path.bounds.top, 340, accuracy: 0.05)
        XCTAssertTrue(seen[3].path.fill && seen[3].path.stroke)
        XCTAssertEqual(session.undoLabel, "Add ellipse")
    }

    func test_manyObjectsMoveInOneStep() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (some text) Tj ET\n" + content)
        let editor = PageEditor(session, 0)
        let all = editor.objects
        let before = try EditKit.glyphs(session)
        let bounds = try EditPaint.paths(session).map { $0.path.bounds }
        let result = try editor.move(all, 7, -3)
        XCTAssertEqual(result.changed, all.count)
        XCTAssertEqual(session.undoLabel, "Move")
        let glyphs = try EditKit.glyphs(session)
        for i in 0..<glyphs.count {
            XCTAssertEqual(glyphs[i].x, before[i].x + 7, accuracy: 0.005)
            XCTAssertEqual(glyphs[i].y, before[i].y - 3, accuracy: 0.005)
        }
        let moved = try EditPaint.paths(session).map { $0.path.bounds }
        for i in 0..<moved.count { XCTAssertEqual(moved[i].left, bounds[i].left + 7, accuracy: 0.005) }
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(before, try EditKit.glyphs(session))
        XCTAssertFalse(session.canUndo)
    }

    func test_aStaleObjectIsRefused() throws {
        let (_, editor) = try open()
        let old = paths(editor)[0]
        _ = try editor.move([old], 1, 1)
        XCTAssertThrowsError(try editor.move([old], 1, 1)) { error in
            XCTAssertTrue(error is ArgumentException, "\(error)")
        }
    }
}
