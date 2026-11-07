import XCTest
@testable import LazyPDFApp

final class SecurityScopedAccessTests: XCTestCase {
    func test_stoppingAGrantTwiceEndsItOnce() {
        var ended = 0
        let access = SecurityScopedAccess(URL(fileURLWithPath: "/tmp/x")) { _ in ended += 1 }

        access.stop()
        access.stop()

        XCTAssertEqual(ended, 1)
    }

    func test_aGrantThatWasNeverStoppedEndsWhenItIsReleased() {
        var ended = 0
        var access: SecurityScopedAccess? = SecurityScopedAccess(URL(fileURLWithPath: "/tmp/x")) { _ in ended += 1 }

        access = nil

        XCTAssertNil(access)
        XCTAssertEqual(ended, 1)
    }
}
