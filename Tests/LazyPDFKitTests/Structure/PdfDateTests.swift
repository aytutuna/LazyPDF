import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/PdfDateTests.cs: the same cases, and one for a date outside the range of
// DateTimeOffset, which throws in the C# and reads as nil here.

final class PdfDateTests: XCTestCase {
    func test_parsesFullDateWithZone() {
        let date = PdfDate.parse("D:20261019213005+03'00'")
        XCTAssertEqual(date, DateTimeOffset(2026, 10, 19, 21, 30, 5, offsetMinutes: 180))
    }

    func test_shortenedFormsFillTheRest() {
        let cases: [(String, Int, Int, Int, Int)] = [
            ("D:2026", 2026, 1, 1, 0),
            ("D:202603", 2026, 3, 1, 0),
            ("D:20260315", 2026, 3, 15, 0),
            ("D:2026031512", 2026, 3, 15, 12),
            ("20260315120000Z", 2026, 3, 15, 12),
            ("D:20260315120000Z00'00'", 2026, 3, 15, 12),
            ("  D:20260315120000  ", 2026, 3, 15, 12),
        ]
        for (text, year, month, day, hour) in cases {
            XCTAssertEqual(PdfDate.parse(text), DateTimeOffset(year, month, day, hour, 0, 0), text)
        }
    }

    func test_negativeAndHalfHourZones() {
        XCTAssertEqual(PdfDate.parse("D:20260101000000-05'00'")?.offsetMinutes, -300)
        XCTAssertEqual(PdfDate.parse("D:20260101000000+05'30'")?.offsetMinutes, 330)
        XCTAssertEqual(PdfDate.parse("D:20260101000000+0530")?.offsetMinutes, 330)
        XCTAssertEqual(PdfDate.parse("D:20260101000000+02")?.offsetMinutes, 120)
    }

    func test_nonsenseIsNull() {
        for text in ["", "D:", "yesterday", "D:20261301", "D:20260230", "D:2026010125", "D:20260101000000+25'00'", "D:00000101"] {
            XCTAssertNil(PdfDate.parse(text), text)
        }
    }

    func test_leapSecondIsClamped() {
        XCTAssertEqual(PdfDate.parse("D:20161231235960Z")?.second, 59)
    }

    func test_formatsBothWays() {
        let date = DateTimeOffset(2026, 10, 19, 21, 30, 5, offsetMinutes: -(3 * 60 + 30))
        XCTAssertEqual(PdfDate.format(date), "D:20261019213005-03'30'")
        XCTAssertEqual(PdfDate.formatXmp(date), "2026-10-19T21:30:05-03:30")
        XCTAssertEqual(PdfDate.parse(PdfDate.format(date)), date)
        XCTAssertEqual(PdfDate.parseXmp(PdfDate.formatXmp(date)), date)
    }

    func test_xmpDatesMayBeShort() {
        XCTAssertEqual(PdfDate.parseXmp("2026-03-01"), DateTimeOffset(2026, 3, 1, 0, 0, 0))
        XCTAssertNil(PdfDate.parseXmp("soon"))
        XCTAssertNil(PdfDate.parseXmp(nil))
    }

    // DateTimeOffset ends at 0001-01-01 and 9999-12-31 in UTC: a zone can push a parsed date out of it.
    func test_dateOutsideTheRangeIsNull() {
        XCTAssertNil(PdfDate.parse("D:00010101000000+05'00'"))
        XCTAssertNil(PdfDate.parse("D:99991231235959-05'00'"))
        XCTAssertNil(PdfDate.parseXmp("0001-01-01T00:00:00+05:00"))
        XCTAssertNotNil(PdfDate.parse("D:00010101000000Z"))
    }

    func test_xmpFractionThatRoundsUpCarries() {
        XCTAssertEqual(PdfDate.parseXmp("2026-03-01T23:59:59.99999999Z"), DateTimeOffset(2026, 3, 2, 0, 0, 0))
        XCTAssertEqual(PdfDate.parseXmp("2026-12-31T23:59:59.99999995+02:00"), DateTimeOffset(2027, 1, 1, 0, 0, 0, offsetMinutes: 120))
        let last = DateTimeOffset(valid: 2026, 3, 1, 23, 59, 59, ticks: 9_999_999)
        XCTAssertEqual(PdfDate.parseXmp("2026-03-01T23:59:59.99999994Z"), last)
        XCTAssertNil(PdfDate.parseXmp("9999-12-31T23:59:59.99999999Z"))
        XCTAssertEqual(PdfDate.parseXmp("2026-03-01T10:20:59.99999999Z")?.minute, 21)
    }
}
