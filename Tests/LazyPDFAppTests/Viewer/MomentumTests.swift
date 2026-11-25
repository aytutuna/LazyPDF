import XCTest
@testable import LazyPDFApp

final class MomentumTests: XCTestCase {
    func test_slowsDownEveryStep() throws {
        var momentum = try XCTUnwrap(Momentum(velocity: ViewPoint(0, 1000)))
        var last = Double.infinity

        while let delta = momentum.step(1.0 / 60) {
            XCTAssertLessThan(delta.y, last)
            last = delta.y
        }
    }

    func test_stopsUnderTheFloor() throws {
        var momentum = try XCTUnwrap(Momentum(velocity: ViewPoint(600, 800)))
        var steps = 0

        while momentum.step(1.0 / 60) != nil {
            steps += 1
            XCTAssertLessThan(steps, 1000)
        }

        XCTAssertNil(momentum.step(1.0 / 60))
    }

    func test_aSlowFingerStartsNothing() {
        XCTAssertNil(Momentum(velocity: ViewPoint(150, 100)))
        XCTAssertNil(Momentum(velocity: ViewPoint(0, 0)))
    }

    func test_travelsAboutTheIntegralOfTheDecay() throws {
        var momentum = try XCTUnwrap(Momentum(velocity: ViewPoint(0, 2000)))
        var total = 0.0

        while let delta = momentum.step(1.0 / 120) { total += delta.y }

        let expected = 2000 / (-1000 * log(0.998))
        XCTAssertEqual(total, expected, accuracy: expected * 0.05)
    }
}
