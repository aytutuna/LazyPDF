import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/PageGeometryTests.cs: the same cases.

final class PageGeometryTests: XCTestCase {
    // A 100 x 200 page whose crop box starts at (10, 20): the corners of the box are known on screen.
    private let box = PdfRect(10, 20, 110, 220)

    func test_cornersLandWhereARotatedPageShowsThem() {
        let cases: [(rotate: Int, x: Double, y: Double, dx: Double, dy: Double)] = [
            (0, 10, 20, 0, 200),     // user bottom-left is the bottom-left of the screen
            (0, 110, 220, 100, 0),   // user top-right is the top-right
            (90, 10, 20, 0, 0),      // turned clockwise, the bottom-left corner goes to the top-left
            (90, 10, 220, 200, 0),   // and the top-left goes to the top-right
            (180, 10, 20, 100, 0),
            (180, 110, 220, 0, 200),
            (270, 10, 20, 200, 100), // bottom-left goes to the bottom-right
            (270, 10, 220, 0, 100),  // top-left goes to the bottom-left
        ]
        for c in cases {
            let geometry = PageGeometry(box, c.rotate)
            let p = geometry.toDisplay(c.x, c.y)
            XCTAssertEqual(p.x, c.dx, accuracy: 1e-9, "\(c)")
            XCTAssertEqual(p.y, c.dy, accuracy: 1e-9, "\(c)")
        }
    }

    func test_sizeFollowsTheRotation() {
        for (rotate, width, height) in [(0, 100.0, 200.0), (90, 200, 100), (180, 100, 200), (270, 200, 100)] {
            let geometry = PageGeometry(box, rotate)
            XCTAssertEqual(geometry.width, width, "\(rotate)")
            XCTAssertEqual(geometry.height, height, "\(rotate)")
        }
    }

    func test_toUserUndoesToDisplay() {
        for (rotate, unit) in [(0, 1.0), (90, 1), (180, 2.5), (270, 0.5)] {
            let geometry = PageGeometry(box, rotate, unit)
            for (x, y) in [(10.0, 20.0), (55.5, 100.25), (110.0, 220.0), (-30.0, 400.0)] {
                let d = geometry.toDisplay(x, y)
                let u = geometry.toUser(d.x, d.y)
                XCTAssertEqual(u.x, x, accuracy: 1e-9, "\(rotate) \(unit)")
                XCTAssertEqual(u.y, y, accuracy: 1e-9, "\(rotate) \(unit)")
            }
        }
    }

    func test_userUnitScalesTheDisplay() {
        let geometry = PageGeometry(box, 0, 2)
        XCTAssertEqual(geometry.width, 200)
        XCTAssertEqual(geometry.height, 400)
        let p = geometry.toDisplay(60, 120)
        XCTAssertEqual(p.x, 100)
        XCTAssertEqual(p.y, 200)
    }

    func test_rectanglesCrossInBothDirections() {
        let geometry = PageGeometry(box, 90)
        let shown = geometry.toDisplay(PdfRect(10, 20, 50, 40))
        XCTAssertEqual(shown, DisplayRect(0, 0, 20, 40))
        XCTAssertEqual(geometry.toUser(shown), PdfRect(10, 20, 50, 40))
    }

    func test_pageGeometryReadsThePage() throws {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
            .obj(3, "<</Type /Page /MediaBox [0 0 600 800] /CropBox [100 100 400 300] /Rotate 90 /UserUnit 2>>")
        let document = try PdfDocument.open(pdf.finish())
        let geometry = PageGeometry(document.pages[0])
        XCTAssertEqual(geometry.width, 400)
        XCTAssertEqual(geometry.height, 600)
        XCTAssertEqual(geometry.rotation, 90)
        let p = geometry.toDisplay(100, 100)
        XCTAssertEqual(p.x, 0)
        XCTAssertEqual(p.y, 0)
    }

    func test_rotationIsKeptToAMultipleOf90() {
        XCTAssertEqual(PageGeometry(box, -90).rotation, 270)
        XCTAssertEqual(PageGeometry(box, 450).rotation, 90)
    }
}
