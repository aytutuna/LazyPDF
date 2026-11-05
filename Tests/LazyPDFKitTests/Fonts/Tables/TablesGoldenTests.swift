import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Tables/TablesGoldenTests.cs: the same cases. The golden files are
// written by the Windows tests.

final class TablesGoldenTests: XCTestCase {
    func test_toUnicodeCMapIsTheGoldenFile() throws {
        try Golden.check("tables", "tounicode-output.txt", TablesGolden.toUnicode(try Golden.input("tables", "tounicode-input.txt")))
    }
}
