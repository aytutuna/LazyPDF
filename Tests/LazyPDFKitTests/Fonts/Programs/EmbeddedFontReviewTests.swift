import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Programs/EmbeddedFontReviewTests.cs: the same cases. They read the
// synthetic font instead of arial.ttf, which the Swift runners do not have: A and B are in it, "a" and U+4E2D are
// not, and its .notdef advance is 500.

final class EmbeddedFontReviewTests: XCTestCase {
    func test_encodeSkipsControlCharactersLikeWidth() throws {
        let data = try SyntheticFonts.ttf()
        let font = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["A\tB"]).font)
        XCTAssertEqual(font.encode("A\tB").count, 4)
    }

    func test_notdefAdvanceIsWrittenWhenCharactersAreMissing() throws {
        let data = try SyntheticFonts.ttf()
        let font = try XCTUnwrap(EmbeddedFontBuilder.build(data, ["A\u{4E2D}"]).font)
        let source = try XCTUnwrap(TrueTypeFont.tryParse(data))
        let first = try XCTUnwrap(font.widths.first { $0.firstCid == 0 })
        XCTAssertEqual(source.getAdvance(0), 500)
        XCTAssertEqual(first.widths[0], Int((Double(source.getAdvance(0)) * 1000.0 / Double(source.unitsPerEm)).rounded(.toNearestOrEven)))
    }
}
