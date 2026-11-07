#if os(macOS)
import XCTest
import AppKit
@testable import LazyPDFMac

// Stands in for the PagePaginator tests of windows/LazyPDF.App.Tests/PrintFlowTests.cs: the operation is built for a
// fixture and not run, since running it opens a print panel.

@MainActor
final class MacSystemPrintTests: XCTestCase {
    func test_theOperationIsBuiltForTheDocumentsCurrentBytes() throws {
        let bytes = try MacPdfs.text(pages: 3)

        let operation = try XCTUnwrap(MacSystemPrint.operation(bytes, password: nil, info: NSPrintInfo()))

        XCTAssertNotNil(operation.view)
    }

    func test_aFileThatIsNotAPdfBuildsNothing() {
        XCTAssertNil(MacSystemPrint.operation([1, 2, 3], password: nil, info: NSPrintInfo()))
    }

    func test_aLockedFileNeedsItsPassword() throws {
        let locked = try MacPdfs.fixture("locked.pdf")

        XCTAssertNil(MacSystemPrint.operation(locked, password: "wrong", info: NSPrintInfo()))
        XCTAssertNotNil(MacSystemPrint.operation(locked, password: "secret", info: NSPrintInfo()))
    }
}
#endif
