import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors the points tests of windows/LazyPDF.App.Tests/Tools/comment/MarkerTests.cs: moving, adding and removing the ends of a
// line and the corners of a polygon.

@MainActor
final class MarkerPointsTests: XCTestCase {
    private let square = [markPt(100, 100), markPt(300, 100), markPt(300, 300), markPt(100, 300)]
    private let drag = [markPt(60, 80), markPt(260, 140)]

    private func again(_ f: CommentFixture, _ a: PdfAnnotation) throws -> PdfAnnotation {
        try XCTUnwrap(f.marks().first { $0.reference?.number == a.reference?.number })
    }

    func test_movingOneEndOfALineLeavesTheOtherAndKeepsBothInTheBox() async throws {
        let f = try CommentFixture()
        let line = try f.marker.add(.line, 0, [markPt(100, 100), markPt(300, 300)], markRed)

        let moved = try f.marker.movePoint(line, 1, markPt(400, 200))

        let ends = try XCTUnwrap(f.marker.pointsOf(moved))
        XCTAssertEqual(ends[0].x, 100, accuracy: 0.5)
        XCTAssertEqual(ends[0].y, 100, accuracy: 0.5)
        XCTAssertEqual(ends[1].x, 400, accuracy: 0.5)
        XCTAssertEqual(ends[1].y, 200, accuracy: 0.5)
        let box = f.marker.box(of: moved)
        XCTAssertTrue(ends.allSatisfy { $0.x >= box.left && $0.x <= box.right && $0.y >= box.top && $0.y <= box.bottom })
        XCTAssertTrue(moved.hasAppearance)
    }

    func test_aCloudHasCornersThatMoveAndKeepRoomForItsBulge() async throws {
        let f = try CommentFixture()
        let cloud = try f.marker.add(.cloud, 0, square, markRed)

        let moved = try f.marker.movePoint(cloud, 2, markPt(350, 350))

        let corners = try XCTUnwrap(f.marker.pointsOf(moved))
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners[2].x, 350, accuracy: 0.5)
        let box = f.marker.box(of: moved)
        XCTAssertTrue(box.right >= 350 + moved.border.width + 1 - 0.01 && box.bottom >= 350 + moved.border.width + 1 - 0.01)
        XCTAssertTrue(moved.cloud > 0)
    }

    func test_aFixedMarkHasNoPoints() async throws {
        let f = try CommentFixture()
        let line = try f.marker.add(.line, 0, drag, markRed)
        line.dictionary["LL"] = PdfNumber(1)
        let foreign = try again(f, line)
        let shape = try f.marker.add(.polygon, 0, square, markRed)
        shape.dictionary["Measure"] = PdfDictionary()
        let measured = try again(f, shape)

        for mark in [foreign, measured] {
            XCTAssertNil(f.marker.pointsOf(mark))
            XCTAssertFalse(Marker.hasPoints(mark))
            XCTAssertThrowsError(try f.marker.movePoint(mark, 0, markPt(10, 10))) { XCTAssertTrue($0 is ArgumentException) }
            XCTAssertThrowsError(try f.marker.insertPoint(mark, after: 0, at: markPt(10, 10)))
            XCTAssertFalse(f.marker.canRemovePoint(mark, 0))
            XCTAssertEqual(f.marker.segmentAt(mark, markPt(200, 100), tolerance: 4), -1)
        }
    }

    func test_aBadPointIndexIsRefusedNotWrittenOver() async throws {
        let f = try CommentFixture()
        let line = try f.marker.add(.line, 0, drag, markRed)
        let shape = try f.marker.add(.polygon, 0, square, markRed)

        for (mark, index) in [(line, 2), (shape, 4), (shape, -1)] {
            XCTAssertThrowsError(try f.marker.movePoint(mark, index, markPt(10, 10))) { XCTAssertTrue($0 is MarkError) }
        }
        XCTAssertThrowsError(try f.marker.insertPoint(shape, after: 4, at: markPt(10, 10))) { XCTAssertTrue($0 is MarkError) }
        XCTAssertThrowsError(try f.marker.removePoint(shape, 4)) { XCTAssertTrue($0 is MarkError) }
        XCTAssertEqual(try again(f, shape).vertices.count, 8)
    }

    func test_aCornerIsAddedInTheMiddleAndOnTheClosingSideOfAPolygon() async throws {
        let f = try CommentFixture()
        let shape = try f.marker.add(.polygon, 0, square, markRed)

        let middle = try f.marker.insertPoint(shape, after: 1, at: markPt(320, 200))
        let closing = try f.marker.insertPoint(middle, after: 4, at: markPt(60, 200))

        let corners = try XCTUnwrap(f.marker.pointsOf(closing))
        XCTAssertEqual(corners.count, 6)
        XCTAssertEqual(corners[1].x, 300, accuracy: 0.5)
        XCTAssertEqual(corners[2].x, 320, accuracy: 0.5)
        XCTAssertEqual(corners[4].x, 100, accuracy: 0.5)
        XCTAssertEqual(corners[5].x, 60, accuracy: 0.5)
        let box = f.marker.box(of: closing)
        XCTAssertTrue(box.left <= 60 && box.right >= 320)
    }

    func test_aCornerAddedThenUndoneLeavesTheOldPolygon() async throws {
        let f = try CommentFixture()
        let shape = try f.marker.add(.polygon, 0, square, markRed)
        XCTAssertTrue(try f.tab.commit("Polygon"))

        _ = try f.marker.insertPoint(try again(f, shape), after: 0, at: markPt(200, 100))
        XCTAssertTrue(try f.tab.commit("Add point"))
        XCTAssertEqual(try again(f, shape).vertices.count, 10)
        XCTAssertTrue(try f.tab.undo())

        XCTAssertEqual(try again(f, shape).vertices.count, 8)
    }

    func test_aCornerCanBeTakenAwayUntilThreeAreLeft() async throws {
        let f = try CommentFixture()
        let shape = try f.marker.add(.polygon, 0, square, markRed)

        XCTAssertTrue(f.marker.canRemovePoint(shape, 3))
        let triangle = try f.marker.removePoint(shape, 1)

        let corners = try XCTUnwrap(f.marker.pointsOf(triangle))
        XCTAssertEqual(corners.count, 3)
        XCTAssertEqual(corners[1].x, 300, accuracy: 0.5)
        XCTAssertEqual(corners[1].y, 300, accuracy: 0.5)
        XCTAssertFalse(f.marker.canRemovePoint(triangle, 0))
        XCTAssertThrowsError(try f.marker.removePoint(triangle, 0)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertEqual(try again(f, triangle).vertices.count, 6)
        XCTAssertFalse(f.marker.canRemovePoint(shape, 4))
    }

    func test_aCloudGetsNoInsertAndNoRemove() async throws {
        let f = try CommentFixture()
        let cloud = try f.marker.add(.cloud, 0, square, markRed)

        XCTAssertFalse(Marker.plainPolygon(cloud))
        XCTAssertFalse(f.marker.canRemovePoint(cloud, 0))
        XCTAssertThrowsError(try f.marker.insertPoint(cloud, after: 0, at: markPt(200, 100)))
    }

    func test_theSideNearestAPointIsFound() async throws {
        let f = try CommentFixture()
        let shape = try f.marker.add(.polygon, 0, square, markRed)

        XCTAssertEqual(f.marker.segmentAt(shape, markPt(200, 102), tolerance: 4), 0)
        XCTAssertEqual(f.marker.segmentAt(shape, markPt(298, 200), tolerance: 4), 1)
        XCTAssertEqual(f.marker.segmentAt(shape, markPt(200, 300), tolerance: 4), 2)
        XCTAssertEqual(f.marker.segmentAt(shape, markPt(100, 200), tolerance: 4), 3)
        XCTAssertEqual(f.marker.segmentAt(shape, markPt(200, 200), tolerance: 4), -1)
    }

    func test_cornersMoveAndComeAndGoInUserSpaceOnATurnedPage() async throws {
        for degrees in [0, 90, 180, 270] {
            let f = try CommentFixture()
            f.document.pages[0].dictionary["Rotate"] = PdfNumber(Double(degrees))
            let shape = try f.marker.add(.polygon, 0, square, markRed)

            let added = try f.marker.insertPoint(shape, after: 1, at: markPt(320, 210))

            var user = f.geometry.toUser(320, 210)
            XCTAssertEqual(added.vertices[4], user.x, accuracy: 0.001, "\(degrees)")
            XCTAssertEqual(added.vertices[5], user.y, accuracy: 0.001, "\(degrees)")
            XCTAssertEqual(try XCTUnwrap(f.marker.pointsOf(added))[2].x, 320, accuracy: 0.001, "\(degrees)")
            let moved = try f.marker.movePoint(added, 2, markPt(340, 220))
            user = f.geometry.toUser(340, 220)
            XCTAssertEqual(moved.vertices[4], user.x, accuracy: 0.001, "\(degrees)")
            XCTAssertEqual(moved.vertices[5], user.y, accuracy: 0.001, "\(degrees)")
            let removed = try f.marker.removePoint(moved, 2)
            XCTAssertEqual(removed.vertices.count, shape.vertices.count, "\(degrees)")
            for (a, b) in zip(removed.vertices, shape.vertices) { XCTAssertEqual(a, b, accuracy: 0.001, "\(degrees)") }
        }
    }

    func test_cornersKeepTheirPlaceOnAPageWithAUserUnit() async throws {
        let f = try CommentFixture()
        f.document.pages[0].dictionary["UserUnit"] = PdfNumber(2)
        let shape = try f.marker.add(.polygon, 0, square, markRed)

        let added = try f.marker.insertPoint(shape, after: 0, at: markPt(200, 100))
        let moved = try f.marker.movePoint(added, 1, markPt(210, 90))

        let user = f.geometry.toUser(210, 90)
        XCTAssertEqual(moved.vertices[2], user.x, accuracy: 0.001)
        XCTAssertEqual(moved.vertices[3], user.y, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(f.marker.pointsOf(moved))[1].x, 210, accuracy: 0.001)
    }
}
