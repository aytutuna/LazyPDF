import XCTest

// Not in the C# tests. The values are what System.Random returned for the same seeds on Windows, so the
// bytes a ported test reads are the bytes its twin reads.

final class SeededRandomTests: XCTestCase {
    func test_seededBytesAreThoseOfSystemRandom() {
        XCTAssertEqual(FilterFixtures.randomBytes(10, 3), [157, 86, 5, 169, 7, 219, 227, 58, 99, 160])
        XCTAssertEqual(FilterFixtures.randomBytes(1000, 8).reduce(0) { $0 + Int($1) }, 127_759)
        var random = DotNetRandom(7)
        XCTAssertEqual((0..<12).map { _ in random.next(6) }, [2, 5, 3, 0, 2, 4, 0, 5, 5, 5, 2, 5])
    }
}
