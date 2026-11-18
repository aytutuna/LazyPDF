import XCTest
@testable import LazyPDFApp

final class TabDragTests: XCTestCase {
    private let strip = CGRect(x: 100, y: 500, width: 800, height: 30)

    private func tearsOut(_ point: CGPoint, taken: Bool = false, escaped: Bool = false) -> Bool {
        TabDrag.tearsOut(taken: taken, escaped: escaped, at: point, strip: strip)
    }

    func test_aDropNearTheStripOpensNoWindow() {
        XCTAssertFalse(tearsOut(CGPoint(x: 400, y: 515)))
        XCTAssertFalse(tearsOut(CGPoint(x: 400, y: 450)))
        XCTAssertFalse(tearsOut(CGPoint(x: 400, y: 589)))
    }

    func test_aDropFarAboveOrBelowOrBesideTheStripOpensAWindow() {
        XCTAssertTrue(tearsOut(CGPoint(x: 400, y: 300)))
        XCTAssertTrue(tearsOut(CGPoint(x: 400, y: 700)))
        XCTAssertTrue(tearsOut(CGPoint(x: 2000, y: 515)))
        XCTAssertTrue(tearsOut(CGPoint(x: 10, y: 515)))
    }

    func test_aDragThatWasTakenOrEscapedOpensNoWindow() {
        XCTAssertFalse(tearsOut(CGPoint(x: 400, y: 300), taken: true))
        XCTAssertFalse(tearsOut(CGPoint(x: 400, y: 300), escaped: true))
    }
}
