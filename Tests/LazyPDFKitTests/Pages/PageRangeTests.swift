import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageRangeTests.cs: the same cases. The cases of Lazy Print's PageRangeTests.cs:
// "1-3, 5, 8-" means the same in all three apps.

final class PageRangeTests: XCTestCase {
    func test_parse_pagesAndRanges_givesZeroBasedIndices() {
        let result = PageRange.parse("1-3, 5, 8-", 10)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.pages, [0, 1, 2, 4, 7, 8, 9])
    }

    func test_parse_orderTypedAndRepeats_areKept() {
        XCTAssertEqual(PageRange.parse("5,1-2,2,1", 8).pages, [4, 0, 1, 1, 0])
    }

    func test_parse_spacesAroundNumbersAndDashes_areIgnored() {
        XCTAssertEqual(PageRange.parse(" 2 - 4 ,  7 ", 8).pages, [1, 2, 3, 6])
    }

    func test_parse_openRangeAtTheLastPage_isThatPage() {
        XCTAssertEqual(PageRange.parse("8-", 8).pages, [7])
    }

    func test_parse_wholeDocument_isEveryPage() {
        XCTAssertEqual(PageRange.parse("1-3", 3).pages, [0, 1, 2])
    }

    func test_parse_pastTheEnd_namesThePage() {
        let cases: [(String, Int, String)] = [
            ("9", 8, "Page 9 is past the end (8 pages)"),
            ("1-12", 8, "Page 12 is past the end (8 pages)"),
            ("9-", 8, "Page 9 is past the end (8 pages)"),
            ("2, 3", 1, "Page 2 is past the end (1 page)"),
            ("1", 0, "Page 1 is past the end (0 pages)"),
        ]
        for (text, pageCount, message) in cases {
            let result = PageRange.parse(text, pageCount)
            XCTAssertFalse(result.isSuccess, text)
            XCTAssertEqual(result.pages, [], text)
            XCTAssertEqual(result.error?.message, message, text)
        }
    }

    func test_parse_notPages_explainsTheFormat() {
        for text in ["", "   ", "abc", "1,,2", "1,", "3-1", "0", "0-2", "-3", "1-2-3", "1.5", "1 2", "99999999999"] {
            let result = PageRange.parse(text, 8)
            XCTAssertFalse(result.isSuccess, text)
            XCTAssertEqual(result.error?.message, "Type pages like 1-3, 5", text)
        }
    }
}
