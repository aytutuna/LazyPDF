import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PageSpaceTests.cs: page space to the view and back, for every rotation the viewer has.

final class PageSpaceTests: XCTestCase {
    private let page = ViewSize(200, 300)

    func test_theTopLeftOfThePageLandsWhereTheRotationPutsIt() {
        for (rotation, viewX, viewY) in [(0, 10.0, 20.0), (90, 310.0, 20.0), (180, 210.0, 320.0), (270, 10.0, 220.0)] {
            let m = PageSpace.toView(page, rotation, 1, ViewPoint(10, 20))

            let at = m.transform(ViewPoint(0, 0))

            XCTAssertEqual(at.x, viewX, accuracy: 1e-6, "\(rotation)")
            XCTAssertEqual(at.y, viewY, accuracy: 1e-6, "\(rotation)")
        }
    }

    func test_theBottomRightOfThePageIsTheOppositeCornerOfTheShownRectangle() {
        for rotation in [0, 90, 180, 270] {
            let origin = ViewPoint(40, 50)
            let shown = PageSpace.shown(page, rotation, 2)
            let m = PageSpace.toView(page, rotation, 2, origin)

            let box = ViewRect(from: m.transform(ViewPoint(0, 0)), to: m.transform(ViewPoint(200, 300)))

            XCTAssertEqual(box.left, origin.x, accuracy: 1e-6)
            XCTAssertEqual(box.top, origin.y, accuracy: 1e-6)
            XCTAssertEqual(box.width, shown.width, accuracy: 1e-6)
            XCTAssertEqual(box.height, shown.height, accuracy: 1e-6)
        }
    }

    func test_aViewPointComesBackToThePointOfThePage() {
        for rotation in [0, 90, 180, 270] {
            let m = PageSpace.toView(page, rotation, 1.7, ViewPoint(13, 29))
            let back = PageSpace.toPage(m)

            for p in [ViewPoint(0, 0), ViewPoint(50, 120.5), ViewPoint(200, 300), ViewPoint(-20, 400)] {
                let again = back.transform(m.transform(p))
                XCTAssertEqual(again.x, p.x, accuracy: 1e-6)
                XCTAssertEqual(again.y, p.y, accuracy: 1e-6)
            }
        }
    }

    func test_aSidewaysRotationSwapsTheShownSize() {
        for (rotation, width, height) in [(0, 200.0, 300.0), (90, 300.0, 200.0), (180, 200.0, 300.0), (270, 300.0, 200.0)] {
            let size = PageSpace.shown(page, rotation, 1)

            XCTAssertEqual(size.width, width)
            XCTAssertEqual(size.height, height)
        }
    }

    func test_aRotationIsKeptToTheNearestRightAngle() {
        for (degrees, expected) in [(0, 0), (90, 90), (-90, 270), (360, 0), (450, 90), (100, 90)] {
            XCTAssertEqual(PageSpace.normalizeRotation(degrees), expected, "\(degrees)")
        }
    }

    func test_aRectangleIsTakenToItsBoundingRectangle() {
        let m = PageSpace.toView(page, 90, 1, ViewPoint(0, 0))

        let box = PageSpace.transform(m, ViewRect(10, 20, 30, 40))

        XCTAssertEqual(box, ViewRect(240, 10, 40, 30))
    }
}
