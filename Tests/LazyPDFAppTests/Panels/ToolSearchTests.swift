import XCTest
@testable import LazyPDFApp

final class ToolSearchTests: XCTestCase {
    func test_noWordsListsEveryTool() {
        XCTAssertEqual(ToolCatalog.search("  ").map(\.id), ToolCatalog.tools.map(\.id))
    }

    func test_aWordFindsToolsByTitleOrSummary() {
        XCTAssertEqual(ToolCatalog.search("REDACT").map(\.id), ["redact"])
        XCTAssertTrue(ToolCatalog.search("password").map(\.id).contains("protect"))
    }

    func test_everyWordMustMatch() {
        XCTAssertEqual(ToolCatalog.search("shrink space").map(\.id), ["optimize"])
        XCTAssertTrue(ToolCatalog.search("shrink zebra").isEmpty)
    }
}
