import XCTest
@testable import LazyPDFApp

final class PageJobsTextTests: XCTestCase {
    @MainActor
    func test_nothingLeftOutSaysNothing() async {
        XCTAssertEqual(PageJobs.leftOutText(0, 0), "")
    }

    @MainActor
    func test_damagedObjectsAreCounted() async {
        XCTAssertEqual(PageJobs.leftOutText(0, 1), "1 damaged object could not be read and was left out.")
        XCTAssertEqual(PageJobs.leftOutText(0, 3), "3 damaged objects could not be read and were left out.")
    }

    @MainActor
    func test_attachmentsAndObjectsShareOneSentence() async {
        XCTAssertEqual(PageJobs.leftOutText(2, 1),
                       "2 attachments could not be read and were left out. 1 damaged object could not be read and was left out.")
    }
}
