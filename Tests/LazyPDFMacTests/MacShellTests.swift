#if os(macOS)
import XCTest
@testable import LazyPDFMac

// Not in the Windows tests: a sandboxed app is handed a path by an address and may not be able to read it.

final class MacAddressTests: XCTestCase {
    func test_aFileTheAppCanReadIsOpened() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("address-\(UUID().uuidString).pdf")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""

        let files = MacShell.split("lazypdf://open?file=" + encoded)

        XCTAssertEqual(files.readable.map(\.path), [file.path])
        XCTAssertTrue(files.refused.isEmpty)
    }

    func test_aFileThatCannotBeReadIsRefused() {
        let files = MacShell.split("lazypdf://open?file=%2Fno%2Fsuch%2Ffolder%2Fa.pdf&file=%2Fno%2Fb.pdf")

        XCTAssertTrue(files.readable.isEmpty)
        XCTAssertEqual(files.refused.map(\.lastPathComponent), ["a.pdf", "b.pdf"])
    }

    func test_anAddressWithNoFileNamesNothing() {
        let files = MacShell.split("lazypdf:")

        XCTAssertTrue(files.readable.isEmpty)
        XCTAssertTrue(files.refused.isEmpty)
    }
}
#endif
