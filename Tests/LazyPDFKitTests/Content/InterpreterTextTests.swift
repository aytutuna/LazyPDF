import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/InterpreterTextTests.cs: the same cases. C# Assert.Equal(expected,
// actual, precision) rounds both to that many decimals; the accuracy here is half of the last one.

final class InterpreterTextTests: XCTestCase {
    private func run(_ content: String, _ resources: String = "/Font <</F1 5 0 R>>", _ objects: [String] = []) throws -> Recorder {
        ContentTestPdf.run(try ContentTestPdf.page(content, resources, [ContentTestPdf.helvetica] + objects))
    }

    func test_glyphsAdvanceByTheirWidths() throws {
        let r = try run("BT /F1 10 Tf 100 200 Td (AB) Tj ET")
        XCTAssertEqual(r.text, "AB")
        XCTAssertEqual(r.glyphs[0].matrix.e, 100, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[0].matrix.f, 200, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[0].matrix.a, 10, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[1].matrix.e, 106.67, accuracy: 5e-3)
        XCTAssertEqual(r.glyphs[0].advance, 6.67, accuracy: 5e-3)
        XCTAssertEqual(r.glyphs[0].character.width, 667)
    }

    func test_boundsCoverAdvanceByAscentAndDescent() throws {
        let b = try run("BT /F1 10 Tf 100 200 Td (A) Tj ET").glyphs[0].bounds
        XCTAssertEqual(b.left, 100, accuracy: 5e-7)
        XCTAssertEqual(b.right, 106.67, accuracy: 5e-3)
        XCTAssertTrue(b.bottom < 200 && b.top > 200)
    }

    func test_theCtmScalesTheGlyph() throws {
        let g = try run("q 2 0 0 3 10 20 cm BT /F1 10 Tf (A) Tj ET Q").glyphs[0]
        XCTAssertEqual(g.matrix.a, 20, accuracy: 5e-7)
        XCTAssertEqual(g.matrix.d, 30, accuracy: 5e-7)
        XCTAssertEqual(g.matrix.e, 10, accuracy: 5e-7)
        XCTAssertEqual(g.matrix.f, 20, accuracy: 5e-7)
    }

    func test_tjAdjustmentsMoveByThousandths() throws {
        let r = try run("BT /F1 10 Tf 100 0 Td [(A) -1000 (B) 500 (C)] TJ ET")
        XCTAssertEqual(r.glyphs[1].matrix.e, 100 + 6.67 + 10, accuracy: 5e-3)
        XCTAssertEqual(r.glyphs[2].matrix.e, 100 + 6.67 + 10 + 6.67 - 5, accuracy: 5e-3)
        XCTAssertEqual(r.glyphs.map { $0.element }, [0, 2, 4])
    }

    func test_spacingAndScaleApply() throws {
        // Space is 278; Tc 1 on each character, Tw 5 on the space, Tz 50 halves the lot.
        let r = try run("BT /F1 10 Tf 1 Tc 5 Tw 50 Tz 0 0 Td (A B) Tj ET")
        XCTAssertEqual(r.glyphs[0].advance, (6.67 + 1) * 0.5, accuracy: 5e-3)
        XCTAssertEqual(r.glyphs[1].advance, (2.78 + 1 + 5) * 0.5, accuracy: 5e-3)
        XCTAssertEqual(r.glyphs[0].matrix.a, 0.5 * 10, accuracy: 5e-7)
    }

    func test_leadingAndQuoteOperators() throws {
        let r = try run("BT /F1 10 Tf 14 TL 100 500 Td (A) Tj T* (B) Tj (C) ' 2 3 (D) \" ET")
        XCTAssertEqual(r.glyphs[1].matrix.f, 486, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[2].matrix.f, 472, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[3].matrix.f, 458, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[3].element, 1)
    }

    func test_tdCapitalSetsTheLeading() throws {
        let r = try run("BT /F1 10 Tf 0 -20 TD (A) Tj T* (B) Tj ET")
        XCTAssertEqual(r.glyphs[1].matrix.f, -40, accuracy: 5e-7)
    }

    func test_tmReplacesTheMatrixAndRiseMovesUp() throws {
        let g = try run("BT /F1 10 Tf 0 1 -1 0 50 60 Tm 4 Ts (A) Tj ET").glyphs[0]
        XCTAssertEqual(g.matrix.e, 50 - 4 * 1, accuracy: 5e-7)
        XCTAssertEqual(g.matrix.f, 60, accuracy: 5e-7)
        XCTAssertEqual(g.matrix.b, 10, accuracy: 5e-7)
    }

    func test_theOperatorAndByteOffsetLocateTheCode() throws {
        let r = try run("BT /F1 10 Tf [(AB) 10 (CD)] TJ ET")
        XCTAssertEqual(r.glyphs.map { $0.offset }, [0, 1, 0, 1])
        XCTAssertEqual(r.`where`.map { $0.index }, [2, 2, 2, 2])
        XCTAssertEqual(r.glyphs.map { $0.element }, [0, 0, 2, 2])
    }

    func test_aMissingFontStillShowsText() throws {
        let r = try run("BT /Nope 10 Tf (AB) Tj ET")
        XCTAssertEqual(r.text, "AB")
        XCTAssertEqual(r.glyphs[0].character.width, 667)
    }

    func test_textBeforeAnyFontUsesTheFallback() throws {
        XCTAssertEqual(try run("BT (A) Tj ET").text, "A")
    }

    func test_renderModeAndFontSizeAreInTheState() throws {
        let r = try run("BT /F1 12 Tf 3 Tr (A) Tj ET")
        XCTAssertEqual(r.renderModes[0], 3)
        XCTAssertEqual(r.glyphs[0].matrix.a, 12, accuracy: 5e-7)
    }

    func test_anExtGStateSetsTheFont() throws {
        let r = try run("/G1 gs BT (A) Tj ET", "/Font <</F1 5 0 R>> /ExtGState <</G1 <</Font [5 0 R 20]>>>>")
        XCTAssertEqual(r.glyphs[0].matrix.a, 20, accuracy: 5e-7)
    }

    func test_type3WidthsFollowTheFontMatrix() throws {
        let type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.002 0 0 0.002 0 0] /FirstChar 65 /LastChar 65 /Widths [500] "
            + "/Encoding <</Type /Encoding /Differences [65 /A]>> /CharProcs <<>>>>"
        let r = try run("BT /T3 10 Tf (AA) Tj ET", "/Font <</T3 6 0 R>>", [type3])
        XCTAssertEqual(r.glyphs[0].character.width, 1000, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[0].advance, 10, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[0].unicode, "A")
    }

    func test_verticalFontsAdvanceDownwards() throws {
        let cid = "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 1000>>"
        let type0 = "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-V /DescendantFonts [7 0 R]>>"
        let r = try run("BT /V 10 Tf 100 500 Td <00010002> Tj ET", "/Font <</V 6 0 R>>", [type0, cid])
        XCTAssertEqual(r.glyphs.count, 2)
        XCTAssertEqual(r.glyphs[0].advance, -10, accuracy: 5e-7)
        // The origin sits half a width left of and 880 above the text position.
        XCTAssertEqual(r.glyphs[0].matrix.e, 100 - 5, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[0].matrix.f, 500 - 8.8, accuracy: 5e-7)
        XCTAssertEqual(r.glyphs[1].matrix.f, 490 - 8.8, accuracy: 5e-7)
    }
}
