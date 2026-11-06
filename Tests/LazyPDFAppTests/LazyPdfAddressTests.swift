import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/LazyPdfAddressTests.cs, with POSIX paths in place of drive letters.

final class LazyPdfAddressTests: XCTestCase {
    func test_onlyTheOwnSchemeIsAnAddress() {
        for (text, expected) in [("lazypdf:", true), ("LazyPDF://open?file=x", true), ("  lazypdf:open", true),
                                 ("lazyprint:open", false), ("/Users/a/lazypdf.pdf", false)] {
            XCTAssertEqual(LazyPdfAddress.isAddress(text), expected, text)
        }
    }

    func test_anAddressWithNoFileJustBringsTheWindowForward() {
        XCTAssertEqual(LazyPdfAddress.parse("lazypdf:"), [])
        XCTAssertEqual(LazyPdfAddress.parse("lazypdf://open"), [])
    }

    func test_networkPathsAreNotOpened() {
        XCTAssertEqual(LazyPdfAddress.parse("lazypdf://open?file=%2F%2Fhost%2Fs%2Fa.pdf"), [])
    }

    func test_filesAreUnescapedAndKeptInOrder() {
        let files = LazyPdfAddress.parse("lazypdf://open?file=%2FUsers%2Fa%2Fa%20b.pdf&file=%2Ftmp%2Fc.pdf")
        XCTAssertEqual(files.map(\.path), ["/Users/a/a b.pdf", "/tmp/c.pdf"])
    }

    func test_aRelativePathIsNotAFile() {
        XCTAssertEqual(LazyPdfAddress.parse("lazypdf://open?file=docs%2Fa.pdf&file=a.pdf"), [])
    }

    func test_otherParametersAreIgnored() {
        XCTAssertEqual(LazyPdfAddress.parse("lazypdf://open?x=1&file=%2Fa.pdf&y").map(\.path), ["/a.pdf"])
    }
}
