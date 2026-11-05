import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/ContentReviewTests.cs: the same cases.

final class ContentReviewTests: XCTestCase {
    private let formEntries = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]"

    private func font(_ d: PdfDocument, _ number: Int) throws -> PdfFont {
        PdfFont.get(d, try XCTUnwrap(d.get(number) as? PdfDictionary))
    }

    func test_aDamagedToUnicodeKeepsTheMetricsAndTheEncoding() throws {
        let d = try ContentTestPdf.page("", "") { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /UniJIS-UCS2-V /DescendantFonts [6 0 R] /ToUnicode 7 0 R>>")
            pdf.obj(6, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Japan1) /Supplement 2>> /DW 900 /W [34 [500]]>>")
            pdf.stream(7, "/Filter /FlateDecode", "not a zlib stream")
        }
        let f = try font(d, 5)
        XCTAssertTrue(f.isVertical)
        XCTAssertEqual(f.decode([0, 0x41])[0].width, 500)
    }

    func test_aDamagedToUnicodeOfASimpleFontKeepsItsWidths() throws {
        let d = try ContentTestPdf.page("", "") { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Foo /FirstChar 65 /LastChar 65 /Widths [333] /ToUnicode 6 0 R>>")
            pdf.stream(6, "/Filter /FlateDecode", "garbage")
        }
        XCTAssertEqual(try font(d, 5).decode(Array("A".utf8))[0].width, 333)
    }

    func test_aToUnicodeAtAnotherCodeWidthStillApplies() throws {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange "
            + "1 beginbfchar <0041> <015F> endbfchar endcmap"
        let narrow = cmap.replacingOccurrences(of: "<0000> <FFFF>", with: "<00> <FF>").replacingOccurrences(of: "<0041>", with: "<41>")
        let d = try ContentTestPdf.page("", "") { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /TrueType /BaseFont /Foo /Encoding /WinAnsiEncoding /ToUnicode 6 0 R>>")
            pdf.stream(6, "", cmap)
            pdf.obj(7, "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [8 0 R] /ToUnicode 9 0 R>>")
            pdf.obj(8, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /DW 500>>")
            pdf.stream(9, "", narrow)
        }
        XCTAssertEqual(try font(d, 5).toText(Array("A".utf8)), "\u{015F}")
        XCTAssertEqual(try font(d, 7).toText([0, 0x41]), "\u{015F}")
    }

    func test_repeatedWidthRangesAreBoundedByTheWork() throws {
        let w = "[" + String(repeating: "0 65535 0 ", count: 4000) + "]"
        let d = try ContentTestPdf.page("", "", [
            "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [6 0 R]>>",
            "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /DW 500 /W \(w) /W2 \(w)>>",
        ])
        let started = Date()
        _ = try font(d, 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "\(Date().timeIntervalSince(started)) s")
    }

    func test_kerningNumbersCostBudget() throws {
        let form = "BT [" + String(repeating: "1 ", count: 1_000_000) + "] TJ ET"
        let page = String(repeating: "/Fm Do ", count: 15)
        let d = try ContentTestPdf.page(page, "/XObject <</Fm 5 0 R>>") { pdf in pdf.stream(5, self.formEntries, form) }
        let interpreter = ContentInterpreter(d)
        interpreter.run(d.pages[0], Recorder())
        XCTAssertTrue(interpreter.isTruncated)
    }

    func test_aFormWithTooManyOperationsIsSkipped() throws {
        let form = String(repeating: "q ", count: 1_200_000)
        let d = try ContentTestPdf.page("/Fm Do 0 0 1 1 re f", "/XObject <</Fm 5 0 R>>") { pdf in pdf.stream(5, self.formEntries, form) }
        XCTAssertEqual(ContentTestPdf.run(d).paths.count, 1)
    }

    func test_thePathSurvivesAFormDrawnInTheMiddleOfIt() throws {
        let d = try ContentTestPdf.page("0 0 m 10 10 l /Fm Do 20 20 l S", "/XObject <</Fm 5 0 R>>") { pdf in pdf.stream(5, self.formEntries, "q Q") }
        XCTAssertEqual(ContentTestPdf.run(d).paths[0].path.segments.count, 3)
    }

    func test_inlineImageLengthThatOverflowsDoesNotThrow() {
        let header = "BI /W 72057594037927928 /H 1024 /IM true ID "
        let length = 1100
        var prefix = Array(("%" + String(repeating: " ", count: length - 2) + "\n").utf8)
        let at = length + header.utf8.count - 1024
        prefix[at] = UInt8(ascii: "E")
        prefix[at + 1] = UInt8(ascii: "I")
        let ops = ContentParser.parse(prefix + ContentTestPdf.latin(header + "abc\nEI Q"))
        XCTAssertTrue(ops.contains { $0.operator == "BI" })
    }
}
