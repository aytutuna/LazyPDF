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
}
