import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactPathTests.cs: the same cases.

final class RedactPathTests: XCTestCase {
    private let hole = PdfRect(200, 200, 300, 300)

    private func run(_ content: String, _ mark: PdfRect? = nil) throws -> (RedactionResult, Recorder) {
        let document = try RedactionKit.page(content)
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, mark ?? hole)])
        let output = try RedactionKit.open(result)
        let recorder = try ContentTestPdf.run(output)
        // The last path is the cover over the mark.
        XCTAssertEqual(recorder.paths.last?.path.bounds, mark ?? hole)
        recorder.paths.removeLast()
        return (result, recorder)
    }

    private func subpaths(_ p: PathInfo) -> [[MarkPoint]] {
        var all: [[MarkPoint]] = []
        for s in p.segments {
            if s.kind == .move { all.append([]) }
            if s.kind != .close, !all.isEmpty { all[all.count - 1].append((s.x1, s.y1)) }
        }
        return all
    }

    private func area(_ p: PathInfo) -> Double { subpaths(p).reduce(0) { $0 + Geometry.area($1) } }

    private func total(_ recorder: Recorder) -> Double { recorder.paths.reduce(0) { $0 + area($1.path) } }

    private func boxes(_ recorder: Recorder) -> [PdfRect] {
        recorder.paths.flatMap { subpaths($0.path) }.map { sub in
            PdfRect(sub.map { $0.x }.min() ?? 0, sub.map { $0.y }.min() ?? 0, sub.map { $0.x }.max() ?? 0, sub.map { $0.y }.max() ?? 0)
        }
    }

    func test_backgroundRectangleIsCutIntoTheRectanglesAroundTheMark() throws {
        let (result, recorder) = try run("0.9 g 100 100 400 400 re f")
        let pieces = boxes(recorder)
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(total(recorder), Double(400 * 400 - 100 * 100), accuracy: 1e-6)
        for p in pieces { XCTAssertTrue(p.intersect(hole).isEmpty) }
        for p in recorder.paths { XCTAssertEqual(p.state.fillColor.components[0], 0.9, accuracy: 1e-6) }
        XCTAssertEqual(result.report.paths, 1)
    }

    func test_rectangleCrossingAnEdgeLeavesWhatIsOutside() throws {
        let (_, recorder) = try run("0 0 1 rg 250 100 200 150 re f")
        XCTAssertEqual(total(recorder), Double(200 * 150 - 50 * 50), accuracy: 1e-6)
        for p in boxes(recorder) { XCTAssertTrue(p.intersect(hole).isEmpty) }
    }

    func test_rectangleInsideTheMarkGoes() throws {
        let (result, recorder) = try run("1 0 0 rg 220 220 20 20 re f 0 0 1 rg 400 400 20 20 re f")
        XCTAssertEqual(recorder.paths.count, 1)
        XCTAssertEqual(recorder.paths[0].path.bounds.left, 400)
        XCTAssertEqual(result.report.paths, 1)
    }

    func test_rectangleRotatedOnThePageIsCutInPageSpace() throws {
        // A quarter turn puts the rectangle at x 200..300, y 150..300: the mark takes its upper two thirds.
        let (_, recorder) = try run("q 0 1 -1 0 300 150 cm 0 0 150 100 re f Q")
        XCTAssertEqual(total(recorder), Double(100 * 50), accuracy: 1e-6)
        for p in boxes(recorder) { XCTAssertTrue(p.intersect(hole).isEmpty) }
    }

    func test_strokedLineThroughTheMarkIsRemovedAndOthersStay() throws {
        let (result, recorder) = try run("2 w 100 250 m 500 250 l S 100 500 m 500 500 l S 100 150 m 500 150 l S")
        XCTAssertEqual(recorder.paths.count, 2)
        XCTAssertFalse(recorder.paths.contains { $0.path.bounds.bottom == 250 })
        XCTAssertEqual(result.report.paths, 1)
    }

    func test_thickLineNearTheMarkIsRemovedBecauseOfItsWidth() throws {
        let (_, thin) = try run("1 w 100 195 m 500 195 l S")
        let (_, thick) = try run("20 w 100 195 m 500 195 l S")
        XCTAssertEqual(thin.paths.count, 1)
        XCTAssertTrue(thick.paths.isEmpty)
    }

    func test_curvedAndFilledAndStrokedShapesCrossingAreRemoved() throws {
        let (_, recorder) = try run("250 250 m 250 400 400 400 400 250 c f 100 100 150 150 re B 0 g 400 100 50 50 re f")
        XCTAssertEqual(recorder.paths.count, 1)
        XCTAssertEqual(recorder.paths[0].path.bounds.left, 400)
    }

    func test_shapeAroundTheMarkWithoutTouchingItStays() throws {
        // A ring: its outline surrounds the mark, its fill (even-odd) does not cover it.
        let (_, recorder) = try run("100 100 m 400 100 l 400 400 l 100 400 l h 150 150 m 350 150 l 350 350 l 150 350 l h f*")
        XCTAssertEqual(recorder.paths.count, 1)
        XCTAssertEqual(recorder.paths[0].path.operator, "f*")
    }

    func test_outlinedGlyphShapeIsRemoved() throws {
        let (_, recorder) = try run("210 210 m 230 210 l 220 240 l h f 10 10 m 30 10 l 20 40 l h f")
        XCTAssertEqual(recorder.paths.count, 1)
    }

    func test_clippingPathIsKeptAndCutsNothing() throws {
        let (_, recorder) = try run("q 150 150 200 200 re W n 0 g 10 10 20 20 re f Q")
        XCTAssertEqual(recorder.paths.count, 2)
        XCTAssertEqual(recorder.paths[1].state.clip.left, 150)
    }

    func test_shadingUnderTheMarkLeavesAHole() throws {
        let document = try RedactionKit.page("/Sh1 sh", "/Shading <</Sh1 << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >> >>")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, hole)])
        let output = try RedactionKit.open(result)
        let content = try RedactionKit.latin(output)
        XCTAssertTrue(content.contains("W*"))
        XCTAssertTrue(content.contains("Sh1 sh"))
    }

    func test_tilingPatternPaintedUnderTheMarkMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Pattern cs /P1 scn 150 150 200 200 re f /Pattern cs /P1 scn 400 400 50 50 re f", "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f")
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, hole)])
    }
}
