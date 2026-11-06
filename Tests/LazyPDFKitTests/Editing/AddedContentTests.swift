import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/AddedContentTests.cs: the same cases. Content added to a page runs after the
// page's own, whatever state that leaves behind, and stays at its level for Order.

final class AddedContentTests: XCTestCase {
    private let red = RgbColor(255, 0, 0), green = RgbColor(0, 255, 0), blue = RgbColor(0, 0, 255)

    private func fills(_ session: PdfEditSession) throws -> [RgbColor] {
        try EditPaint.paths(session).map { $0.fill }
    }

    func test_aStrayRestoreDoesNotPopAWrapperAndAddedTextStartsFromTheIdentityMatrix() throws {
        let session = try EditKit.session("1 0 0 1 100 0 cm Q BT /F1 12 Tf 50 700 Td (page) Tj ET 2 0 0 2 0 0 cm")
        let before = try EditKit.glyphs(session)
        let result = try PageEditor(session, 0, EditArialSource()).addTextBox(PdfRect(100, 300, 300, 400), "new")
        XCTAssertTrue(result.done, result.problem ?? "")
        let after = try EditKit.glyphs(session)
        XCTAssertEqual(before, Array(after.prefix(before.count)))
        let added = after[before.count]
        XCTAssertEqual(added.x, 100, accuracy: 0.5)
        XCTAssertEqual(added.size, 12, accuracy: 0.05)
    }

    func test_aCleanPageGetsNoWrapperAroundItsContent() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q")
        _ = try PageEditor(session, 0).addRectangle(PdfRect(100, 100, 150, 150), ShapeStyle(stroke: nil, fill: blue))
        let streams = try XCTUnwrap(session.document.pages[0].dictionary["Contents"] as? PdfArray)
        XCTAssertEqual(streams.items.count, 2)
        XCTAssertEqual(EditKit.latin(session).components(separatedBy: "\n")[0], "q 1 0 0 rg 0 0 50 50 re f Q")
    }

    func test_orderPassesAnAddedShapeOnACleanPage() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q q 0 1 0 rg 100 0 50 50 re f Q")
        let editor = PageEditor(session, 0)
        XCTAssertTrue(try editor.addRectangle(PdfRect(200, 0, 250, 50), ShapeStyle(stroke: nil, fill: blue)).done)
        XCTAssertEqual(try fills(session), [red, green, blue])
        let middle = editor.objects.compactMap { $0 as? PathObject }[1]
        XCTAssertTrue(try editor.order(middle, .front).done)
        XCTAssertEqual(try fills(session), [red, blue, green])
    }

    func test_orderSwapsTwoAddedShapes() throws {
        let session = try EditKit.session("q 1 0 0 rg 0 0 50 50 re f Q")
        let editor = PageEditor(session, 0)
        _ = try editor.addRectangle(PdfRect(100, 0, 150, 50), ShapeStyle(stroke: nil, fill: green))
        _ = try editor.addRectangle(PdfRect(200, 0, 250, 50), ShapeStyle(stroke: nil, fill: blue))
        let shapes = editor.objects.compactMap { $0 as? PathObject }
        XCTAssertEqual(shapes.count, 3)
        XCTAssertTrue(try editor.order(shapes[1], .forward).done)
        XCTAssertEqual(try fills(session), [red, blue, green])
    }

    func test_orderStaysBehindTextThatClipsAtItsEnd() throws {
        let content = "q 1 0 0 rg 0 0 50 50 re f Q BT /F1 40 Tf 7 Tr 0 0 Td (XX) Tj ET q 0 0 1 rg 0 0 50 50 re f Q"
        let session = try EditKit.session(content)
        let editor = PageEditor(session, 0)
        let paths = editor.objects.compactMap { $0 as? PathObject }
        XCTAssertFalse(try editor.order(paths[1], .back).done)
        XCTAssertEqual(EditKit.latin(session), content)
    }
}
