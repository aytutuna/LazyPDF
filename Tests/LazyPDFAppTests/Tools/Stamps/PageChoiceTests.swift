import XCTest
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/stamps/PageChoiceTests.cs: which pages a stamp goes on, as the form states it.

final class PageChoiceTests: XCTestCase {
    func test_everyPageIsNoListAtAll() {
        let all = PageChoice.resolve(.all, "", 5)

        XCTAssertNil(all.pages)
        XCTAssertNil(all.error)
    }

    func test_oddAndEvenCountFromTheFirstPageAsOne() {
        XCTAssertEqual(PageChoice.resolve(.odd, "", 5).pages, [0, 2, 4])
        XCTAssertEqual(PageChoice.resolve(.even, "", 5).pages, [1, 3])
    }

    func test_typedPagesComeBackZeroBased() {
        let typed = PageChoice.resolve(.typed, "1-3, 5", 6)

        XCTAssertNil(typed.error)
        XCTAssertEqual(typed.pages, [0, 1, 2, 4])
    }

    func test_aTypoOrAPastThePageCountIsAnError() {
        XCTAssertNotNil(PageChoice.resolve(.typed, "", 6).error)
        XCTAssertNotNil(PageChoice.resolve(.typed, "2-x", 6).error)
        XCTAssertNotNil(PageChoice.resolve(.typed, "9", 6).error)
    }

    func test_targetsDropRepeatsAndPagesThatAreNotThere() {
        XCTAssertEqual(PageChoice.targets([2, 0, 2, 7, -1], 3), [0, 2])
        XCTAssertEqual(PageChoice.targets(nil, 3), [0, 1, 2])
        XCTAssertTrue(PageChoice.targets([], 3).isEmpty)
    }

    func test_aRunsPagesReadBackAsARange() {
        XCTAssertEqual(PageChoice.describe([0, 1, 2, 4]), "1-3, 5")
        XCTAssertEqual(PageChoice.describe([1]), "2")
        XCTAssertEqual(PageChoice.describe([4, 0, 2]), "1, 3, 5")
    }
}
