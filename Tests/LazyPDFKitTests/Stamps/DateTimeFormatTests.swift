import XCTest
@testable import LazyPDFKit

// No C# twin: DateTimeFormat.swift stands in for DateTimeOffset.ToString, which the golden file checks against .NET for the
// fixed day. These are the cases that day cannot show: no fraction of a second, the UTC clock on the other side of midnight,
// and the formats .NET refuses.

final class DateTimeFormatTests: XCTestCase {
    private func format(_ day: DateTimeOffset, _ pattern: String, _ culture: CultureInfo = .invariantCulture) throws -> String {
        try day.toString(pattern, culture)
    }

    func test_aFractionThatIsNotThereTakesItsDotWithIt() throws {
        let day = DateTimeOffset(2026, 3, 9, 14, 5, 7, offsetMinutes: 180)
        XCTAssertEqual(try format(day, "ss.FFF"), "07")
        XCTAssertEqual(try format(day, "ss.%F"), "07")
        XCTAssertEqual(try format(day, "ss.%f"), "07.0")
        XCTAssertEqual(try format(day, "ss,%F"), "07,")
    }

    func test_aSingleSupplementaryCharacterIsACustomFormat() throws {
        let day = DateTimeOffset(2026, 3, 9, 14, 5, 7)
        XCTAssertEqual(try format(day, "\u{1F600}"), "\u{1F600}")
    }

    func test_theUtcFormatsMoveTheDayAcrossMidnight() throws {
        let behind = DateTimeOffset(2026, 12, 31, 23, 30, 5, offsetMinutes: -300)
        XCTAssertEqual(try format(behind, "r"), "Fri, 01 Jan 2027 04:30:05 GMT")
        XCTAssertEqual(try format(behind, "u"), "2027-01-01 04:30:05Z")
        let ahead = DateTimeOffset(2026, 1, 1, 0, 15, 0, offsetMinutes: 180)
        XCTAssertEqual(try format(ahead, "R"), "Wed, 31 Dec 2025 21:15:00 GMT")
        XCTAssertEqual(try format(ahead, "u"), "2025-12-31 21:15:00Z")
        let leap = DateTimeOffset(2024, 3, 1, 0, 30, 0, offsetMinutes: 60)
        XCTAssertEqual(try format(leap, "u"), "2024-02-29 23:30:00Z")
        XCTAssertEqual(try format(leap, "r", CultureInfo("tr-TR")), "Thu, 29 Feb 2024 23:30:00 GMT")
    }

    func test_theOneLetterFormatsFollowTheCulture() throws {
        let day = DateTimeOffset(2026, 3, 9, 14, 5, 7, offsetMinutes: 180)
        XCTAssertEqual(try format(day, "d", CultureInfo("tr-TR")), "9.03.2026")
        XCTAssertEqual(try format(day, "d", CultureInfo("en-US")), "3/9/2026")
        XCTAssertEqual(try format(day, "t", CultureInfo("en-US")), "2:05 PM")
        XCTAssertEqual(try format(day, "d"), "03/09/2026")
        XCTAssertEqual(try format(day, ""), "03/09/2026 14:05:07 +03:00")
    }

    func test_formatsDotNetRefusesAreRefused() {
        let day = DateTimeOffset(2026, 3, 9, 14, 5, 7)
        for pattern in ["U", "x", "%", "%%", "'day", "d\\", "ffffffff"] {
            XCTAssertThrowsError(try format(day, pattern), pattern) { error in
                XCTAssertTrue(error is FormatException)
            }
        }
    }
}
