import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/TextSourceTests.cs: the text of a file as the viewer reads it, apart from the tab's own document.

final class TextSourceTests: XCTestCase {
    func test_eachPageGivesItsText() async throws {
        let source = try await XCTUnwrapAsync(await TextSource.open(try TestPdfs.text(pages: 3), password: nil))

        let second = await source.get(1)

        XCTAssertEqual(source.pageCount, 3)
        XCTAssertTrue(second?.text.contains("Page 2.") == true)
    }

    func test_aPageIsOnlyThereToPeekAtOnceItWasAskedFor() async throws {
        let source = try await XCTUnwrapAsync(await TextSource.open(try TestPdfs.text(pages: 2), password: nil))
        XCTAssertNil(source.peek(0))

        let page = await source.get(0)

        XCTAssertNotNil(page)
        XCTAssertTrue(source.peek(0) === page)
    }

    func test_aPageThatIsNotThereIsNil() async throws {
        let source = try await XCTUnwrapAsync(await TextSource.open(try TestPdfs.text(pages: 1), password: nil))

        let past = await source.get(5)
        let before = await source.get(-1)

        XCTAssertNil(past)
        XCTAssertNil(before)
    }

    func test_aFileThatNeedsAPasswordTheViewerLacksGivesNoSource() async throws {
        let locked = [UInt8](try Data(contentsOf: TestPdfs.fixture("locked.pdf")))

        let without = await TextSource.open(locked, password: nil)
        let with = await TextSource.open(locked, password: "secret")

        XCTAssertNil(without)
        XCTAssertNotNil(with)
    }

    func test_theSourceReadsTheBytesItWasGivenNotTheTabsLaterOnes() async throws {
        let bytes = try TestPdfs.text(pages: 1, line: "Before the edit")
        let source = try await XCTUnwrapAsync(await TextSource.open(bytes, password: nil))

        let page = await source.get(0)

        XCTAssertTrue(page?.text.contains("Before the edit") == true)
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    guard let found = try await value() else {
        XCTFail("Expected a value", file: file, line: line)
        throw CancellationError()
    }
    return found
}
