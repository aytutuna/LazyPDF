import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactGeometryTests.cs: the same cases.

final class RedactGeometryTests: XCTestCase {
    private func area(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> MarkArea {
        MarkArea.of(RedactionMark.fromRect(0, PdfRect(x1, y1, x2, y2)).quads[0])
    }

    func test_quadsInAnyCornerOrderMakeTheSameArea() {
        let a = MarkArea([(0, 0), (10, 0), (10, 5), (0, 5)])
        let b = MarkArea([(10, 5), (0, 0), (0, 5), (10, 0)])
        XCTAssertEqual(a.area, 50, accuracy: 1e-6)
        XCTAssertEqual(a.points.count, b.points.count)
        for (p, q) in zip(a.points, b.points) {
            XCTAssertEqual(p.x, q.x)
            XCTAssertEqual(p.y, q.y)
        }
    }

    func test_glyphMeetsOnlyWhenTheMarkReachesItsMiddle() {
        let glyph = Geometry.corners(PdfMatrix.identity, 0, 0, 10, 10)
        XCTAssertTrue(Geometry.glyphMeets(glyph, area(4, 4, 6, 6)))
        XCTAssertTrue(Geometry.glyphMeets(glyph, area(-5, -5, 3, 3)))
        XCTAssertFalse(Geometry.glyphMeets(glyph, area(9, -5, 20, 20)))
        XCTAssertFalse(Geometry.glyphMeets(glyph, area(10, 0, 20, 10)))
        XCTAssertFalse(Geometry.glyphMeets(glyph, area(-20, 0, 0, 10)))
    }

    func test_zeroWidthGlyphIsTestedAtItsPoint() {
        let mark = area(0, 0, 10, 10)
        XCTAssertTrue(Geometry.glyphMeets(Geometry.corners(PdfMatrix.identity, 5, 0, 5, 10), mark))
        XCTAssertFalse(Geometry.glyphMeets(Geometry.corners(PdfMatrix.identity, 15, 0, 15, 10), mark))
    }

    func test_rotatedGlyphIsTestedInItsOwnFrame() {
        let turned = PdfMatrix(0, 1, -1, 0, 0, 0)
        let glyph = Geometry.corners(turned, 0, 0, 10, 2)
        XCTAssertTrue(Geometry.glyphMeets(glyph, area(-3, 2, 0, 6)))
        XCTAssertFalse(Geometry.glyphMeets(glyph, area(5, 2, 8, 6)))
    }

    func test_segmentDistance() {
        let mark = area(0, 0, 10, 10)
        XCTAssertEqual(Geometry.distance((-5, 5), (15, 5), mark), 0)
        XCTAssertEqual(Geometry.distance((5, 5), (6, 6), mark), 0)
        XCTAssertEqual(Geometry.distance((-3, 20), (-3, -20), mark), 3, accuracy: 1e-6)
        XCTAssertEqual(Geometry.distance((15, 0), (15, 10), mark), 5, accuracy: 1e-6)
        XCTAssertEqual(Geometry.distance((-5, 15), (-5, 20), mark), 50.0.squareRoot(), accuracy: 1e-6)
    }

    func test_fillRuleInsideTest() {
        let ring: [[MarkPoint]] = [[(0, 0), (10, 0), (10, 10), (0, 10)], [(3, 3), (7, 3), (7, 7), (3, 7)]]
        XCTAssertTrue(Geometry.inside(ring, false, 5, 5))
        XCTAssertFalse(Geometry.inside(ring, true, 5, 5))
        XCTAssertTrue(Geometry.inside(ring, true, 1, 1))
        XCTAssertFalse(Geometry.inside(ring, true, 20, 5))
    }
}
