import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Programs/StandardNamesTests.cs: the same cases, except CffStringsMatch,
// MacintoshGlyphOrderMatches, StandardEncodingMatches and PredefinedCharsetsAgreeWithTheStrings, which compare the
// tables with the copies PdfPig carries. Swift has no PdfPig; standard-names-output.txt in the golden files pins
// the same tables, written by the C# side.

final class StandardNamesTests: XCTestCase {
    func test_tablesHaveTheSizesTheSpecsGive() {
        XCTAssertEqual(StandardNames.cffStrings.count, 391)
        XCTAssertEqual(StandardNames.macGlyphs.count, 258)
        XCTAssertEqual(StandardNames.standardEncoding.count, 256)
        XCTAssertEqual(StandardNames.standardEncodingSids.count, 256)
        XCTAssertEqual(StandardNames.cffStrings.count, Set(StandardNames.cffStrings).count)
    }

    func test_standardEncodingSidsNameTheSameGlyphs() {
        for code in 0..<256 {
            let name = StandardNames.standardEncoding[code]
            let sid = StandardNames.standardEncodingSids[code]
            if let name {
                XCTAssertEqual(name, StandardNames.cffStrings[sid], "code \(code)")
            } else {
                XCTAssertEqual(sid, 0, "code \(code)")
            }
        }
    }
}
