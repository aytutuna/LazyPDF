import XCTest
@testable import LazyPDFApp

// Where the text control of an open field goes: upright and the size of the field's area at any rotation of the view.

final class OverlayFieldFrameTests: XCTestCase {
    private let page = ViewSize(612, 792)
    private let area = ViewRect(100, 50, 200, 20)

    private func matrix(_ rotation: Int) -> ViewMatrix {
        PageSpace.toView(page, rotation, 1.5, ViewPoint(10, 20))
    }

    func test_theFrameIsTheAreaTimesTheScaleWhenTheViewIsNotTurned() {
        let frame = OverlayFieldFrame.of(area, matrix(0), used: nil, wraps: true)

        XCTAssertEqual(frame, ViewRect(160, 95, 300, 30))
    }

    func test_aQuarterTurnKeepsTheWidthAndHeightAndMovesTheCentre() {
        let frame = OverlayFieldFrame.of(area, matrix(90), used: nil, wraps: true)

        XCTAssertEqual(frame.width, 300, accuracy: 1e-9)
        XCTAssertEqual(frame.height, 30, accuracy: 1e-9)
        XCTAssertEqual(frame.x, 958, accuracy: 1e-9)
        XCTAssertEqual(frame.y, 305, accuracy: 1e-9)
    }

    func test_atEveryRotationTheFrameIsCentredWhereTheAreaLands() {
        let middle = ViewPoint(area.x + area.width / 2, area.y + area.height / 2)
        for rotation in [0, 90, 180, 270] {
            let matrix = matrix(rotation)
            let frame = OverlayFieldFrame.of(area, matrix, used: nil, wraps: true)
            let centre = matrix.transform(middle)

            XCTAssertEqual(frame.width, 300, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(frame.height, 30, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(frame.x + frame.width / 2, centre.x, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(frame.y + frame.height / 2, centre.y, accuracy: 1e-9, "\(rotation)")
        }
    }

    func test_theScaleIsTheSameAtEveryRotation() {
        for rotation in [0, 90, 180, 270] {
            XCTAssertEqual(ViewScale.of(matrix(rotation)), 1.5, accuracy: 1e-9, "\(rotation)")
        }
    }

    func test_textThatNeedsMoreRoomGrowsTheFrameDownAndAFieldThatDoesNotWrapAlsoToTheRight() {
        let used = ViewSize(400, 50)

        let wrapped = OverlayFieldFrame.of(area, matrix(0), used: used, wraps: true)
        let line = OverlayFieldFrame.of(area, matrix(0), used: used, wraps: false)

        XCTAssertEqual(wrapped, ViewRect(160, 95, 300, 50))
        XCTAssertEqual(line, ViewRect(160, 95, 400, 50))
    }

    func test_textThatFitsLeavesTheFrameAlone() {
        let frame = OverlayFieldFrame.of(area, matrix(0), used: ViewSize(100, 10), wraps: false)

        XCTAssertEqual(frame, ViewRect(160, 95, 300, 30))
    }

    private func pageBounds(_ matrix: ViewMatrix) -> ViewRect {
        PageSpace.transform(matrix, ViewRect(0, 0, page.width, page.height))
    }

    func test_aFrameInsideThePageIsLeftWhereItIs() {
        let middle = ViewRect(250, 400, 100, 20)
        for rotation in [0, 90, 180, 270] {
            let matrix = matrix(rotation)
            let plain = OverlayFieldFrame.of(middle, matrix, used: nil, wraps: true)
            let bounded = OverlayFieldFrame.of(middle, matrix, used: nil, wraps: true, bounds: pageBounds(matrix))

            XCTAssertEqual(bounded, plain, "\(rotation)")
        }
    }

    func test_aWideFieldAtThePageEdgeIsShiftedIntoThePageAtEveryRotation() {
        let wide = ViewRect(400, 700, 200, 90)
        for rotation in [0, 90, 180, 270] {
            let matrix = matrix(rotation)
            let bounds = pageBounds(matrix)
            let frame = OverlayFieldFrame.of(wide, matrix, used: nil, wraps: true, bounds: bounds)

            XCTAssertEqual(frame.width, 300, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(frame.height, 135, accuracy: 1e-9, "\(rotation)")
            XCTAssertGreaterThanOrEqual(frame.x, bounds.x - 1e-9, "\(rotation)")
            XCTAssertGreaterThanOrEqual(frame.y, bounds.y - 1e-9, "\(rotation)")
            XCTAssertLessThanOrEqual(frame.right, bounds.right + 1e-9, "\(rotation)")
            XCTAssertLessThanOrEqual(frame.bottom, bounds.bottom + 1e-9, "\(rotation)")
        }
    }

    func test_aFrameThatDoesNotFitAnAxisIsAlignedToThePageTopOrLeft() {
        let tall = ViewRect(0, 0, 50, 900)
        let matrix = matrix(90)
        let bounds = pageBounds(matrix)
        let frame = OverlayFieldFrame.of(tall, matrix, used: nil, wraps: true, bounds: bounds)

        XCTAssertEqual(frame.width, 75, accuracy: 1e-9)
        XCTAssertEqual(frame.height, 1350, accuracy: 1e-9)
        XCTAssertEqual(frame.y, bounds.y, accuracy: 1e-9)
    }

    func test_growthKeepsTheTopLeftAndStopsAtThePageEdges() {
        let near = ViewRect(500, 700, 100, 20)
        for rotation in [0, 90, 180, 270] {
            let matrix = matrix(rotation)
            let bounds = pageBounds(matrix)
            let first = OverlayFieldFrame.of(near, matrix, used: nil, wraps: false, bounds: bounds)
            let grown = OverlayFieldFrame.of(near, matrix, used: ViewSize(2000, 2000), wraps: false, bounds: bounds)

            XCTAssertEqual(grown.x, first.x, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(grown.y, first.y, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(grown.right, bounds.right, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(grown.bottom, bounds.bottom, accuracy: 1e-9, "\(rotation)")
        }
    }

    func test_aWrappedFieldIsNotWidenedAndAControlThatCannotScrollAcrossIsNotCapped() {
        let matrix = matrix(0)
        let bounds = pageBounds(matrix)
        let used = ViewSize(5000, 10)

        let wrapped = OverlayFieldFrame.of(area, matrix, used: used, wraps: true, bounds: bounds)
        let loose = OverlayFieldFrame.of(area, matrix, used: used, wraps: false, bounds: bounds, scrollsAcross: false)
        let capped = OverlayFieldFrame.of(area, matrix, used: used, wraps: false, bounds: bounds)

        XCTAssertEqual(wrapped.width, 300, accuracy: 1e-9)
        XCTAssertEqual(loose.width, 5000, accuracy: 1e-9)
        XCTAssertEqual(capped.right, bounds.right, accuracy: 1e-9)
    }

    func test_theCapNeverShrinksTheFirstSizeFrame() {
        let matrix = matrix(0)
        let whole = ViewRect(0, 0, 612, 792)
        let frame = OverlayFieldFrame.of(whole, matrix, used: ViewSize(10, 10), wraps: false, bounds: pageBounds(matrix))

        XCTAssertEqual(frame.size, ViewSize(918, 1188))
    }

    func test_theFootprintOfAFieldInTheMiddleOfThePageIsTheAreaSwappedAtAQuarterTurn() {
        XCTAssertEqual(OverlayFieldFrame.uprightPageRect(area, rotation: 0, page: page), area)
        XCTAssertEqual(OverlayFieldFrame.uprightPageRect(area, rotation: 180, page: page), area)
        XCTAssertEqual(OverlayFieldFrame.uprightPageRect(area, rotation: 90, page: page), ViewRect(190, 0, 20, 200))
        XCTAssertEqual(OverlayFieldFrame.uprightPageRect(area, rotation: 270, page: page), ViewRect(190, 0, 20, 200))
    }

    func test_theFootprintIsTheRectangleTheFramePlacementCoversAtEveryRotation() {
        let edge = ViewRect(400, 700, 200, 90)
        for rotation in [0, 90, 180, 270] {
            let matrix = matrix(rotation)
            let frame = OverlayFieldFrame.of(edge, matrix, used: nil, wraps: true, bounds: pageBounds(matrix))
            let back = PageSpace.transform(matrix.inverted(), frame)
            let footprint = OverlayFieldFrame.uprightPageRect(edge, rotation: rotation, page: page)

            XCTAssertEqual(footprint.x, back.x, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(footprint.y, back.y, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(footprint.width, back.width, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(footprint.height, back.height, accuracy: 1e-9, "\(rotation)")
        }
    }

    func test_theFootprintAtThePageEdgeIsThePlacedOneNotTheUnclampedOne() {
        let edge = ViewRect(500, 10, 100, 20)

        let footprint = OverlayFieldFrame.uprightPageRect(edge, rotation: 90, page: page)

        XCTAssertEqual(footprint, ViewRect(540, 0, 20, 100))
    }

    func test_aPagePointIsLocalToTheControlByTheAreaAndTheScaleAtEveryRotation() {
        for rotation in [0, 90, 180, 270] {
            let scale = ViewScale.of(matrix(rotation))
            let first = OverlayFieldFrame.local(area.topLeft, in: area, scale: scale)
            let middle = OverlayFieldFrame.local(area.center, in: area, scale: scale)

            XCTAssertEqual(first, ViewPoint(0, 0), "\(rotation)")
            XCTAssertEqual(middle.x, 150, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(middle.y, 15, accuracy: 1e-9, "\(rotation)")
        }
    }
}
