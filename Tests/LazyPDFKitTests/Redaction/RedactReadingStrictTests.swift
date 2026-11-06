import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactReadingStrictTests.cs: the same cases. Content that a viewer may place or
// measure differently from the scan is not redacted in place.

final class RedactReadingStrictTests: XCTestCase {
    private let word = RedactionFiles.word

    func test_formMatrixThatIsNotSixNumbersMakesAPicture() throws {
        for matrix in ["[1 0 0 1 null 300]", "[1 0 0 1 0 300 0]", "[1 0 0 1 /X 300]"] {
            let document = try RedactionFiles.open("/Fm1 Do", "/XObject <</Fm1 6 0 R>>") { pdf in
                pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Matrix \(matrix) /Resources <</Font <</F1 5 0 R>>>>", self.word)
            }
            try RedactionKit.assertFlattened(document, PdfRect(90, 390, 300, 420), "ZQXSECRET")
        }
    }

    private func widths(_ first: Int, _ last: Int, _ width: Int) -> String {
        "/FirstChar \(first) /LastChar \(last) /Widths [\(Array(repeating: String(width), count: last - first + 1).joined(separator: " "))]"
    }

    func test_widthsThatAreNotTheViewersMakeAPicture() throws {
        for (first, last, width, count) in [(32, 126, 50000, 95), (32, 126, -5, 95), (65, 65, 500, 60)] {
            let list = "/FirstChar \(first) /LastChar \(last) /Widths [\(Array(repeating: String(width), count: count).joined(separator: " "))]"
            let document = try RedactionFiles.open("BT /F2 12 Tf -593 Tc 100 100 Td (ZQXSECRET) Tj ET", "", { pdf in
                pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica \(list)>>")
            }, fonts: "/F2 6 0 R")
            try RedactionKit.assertFlattened(document, PdfRect(95, 95, 185, 125), "ZQXSECRET")
        }
    }

    func test_widthsThatAgreeWithTheirRangeStayText() throws {
        let document = try RedactionFiles.open("BT /F2 12 Tf 100 100 Td (ZQXSECRET) Tj ET", "", { pdf in
            pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica \(self.widths(32, 126, 500))>>")
        }, fonts: "/F2 6 0 R")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, RedactionFiles.over)])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSECRET"))
    }

    func test_fontWithoutWidthsThatIsNeitherStandardNorEmbeddedMakesAPicture() throws {
        let document = try RedactionFiles.open("BT /F2 12 Tf 100 100 Td (ZQXSECRET) Tj ET", "", { pdf in
            pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Garamond>>")
        }, fonts: "/F2 6 0 R")
        try RedactionKit.assertFlattened(document, RedactionFiles.over, "ZQXSECRET")
    }

    func test_compositeFontWithAnAbsurdDefaultWidthMakesAPicture() throws {
        let document = try RedactionFiles.open("BT /F2 12 Tf 100 100 Td <005A0051> Tj ET", "", { pdf in
            pdf.obj(6, "<</Type /Font /Subtype /Type0 /BaseFont /Helvetica /Encoding /Identity-H /DescendantFonts [7 0 R]>>")
            pdf.obj(7, "<</Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 50000>>")
        }, fonts: "/F2 6 0 R")
        try RedactionKit.assertFlattened(document, RedactionFiles.over)
    }

    func test_imageDataHoldingEiMakesAPicture() throws {
        var data = "x\nEI\nBT /F1 12 Tf 100 100 Td (ZQXSECRET) Tj ET\nq\n"
        data += String(repeating: "p", count: 1000 - data.utf16.count)
        let document = try RedactionFiles.open("q 10 0 0 10 500 700 cm BI /W 1000 /H 1 /BPC 8 /CS /G ID \(data)\nEI Q")
        try RedactionKit.assertFlattened(document, RedactionFiles.over, "ZQXSECRET")
    }

    func test_textOperatorsOutsideATextObjectMakeAPicture() throws {
        let document = try RedactionFiles.open("BT /F1 12 Tf 100 100 Td ET q BT 300 300 Td ET Q (ZQXSECRET) Tj")
        try RedactionKit.assertFlattened(document, RedactionFiles.over, "ZQXSECRET")
    }

    func test_numbersAboveWhatAFloatKeepsMakeAPicture() throws {
        let document = try RedactionFiles.open("q 1 0 0 1 1000000000 0 cm 1 0 0 1 -999999900 0 cm BT /F1 12 Tf 0 100 Td (ZQXSECRET) Tj ET Q")
        try RedactionKit.assertFlattened(document, RedactionFiles.over, "ZQXSECRET")
    }

    func test_namedPatternSpaceDoesNotFlattenAPageWhosePatternIsFarFromTheMark() throws {
        let document = try RedactionFiles.open("/Cs1 cs 0 0 0 /P1 scn 400 600 50 50 re f 0 g " + word, "/ColorSpace <</Cs1 [/Pattern /DeviceRGB]>> /Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, "/PatternType 1 /PaintType 2 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <<>>", "0 0 5 5 re f")
        }
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, RedactionFiles.over)])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSECRET"))
    }

    private func type3(_ differences: String, _ matrix: String = "[0.001 0 0 0.001 0 0]") -> String {
        "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix \(matrix) /CharProcs <</a 7 0 R /evil 8 0 R>> /Encoding <</Type /Encoding /Differences [\(differences)]>> /FirstChar 97 /LastChar 97 /Widths [1000]>>"
    }

    func test_type3FontWithMoreDifferencesThanAreReadMakesAPicture() throws {
        let document = try RedactionFiles.open("BT /F2 10 Tf 50 50 Td (a) Tj ET", "", { pdf in
            pdf.obj(6, self.type3(String(repeating: "97 /a ", count: 2100) + "97 /evil"))
            pdf.stream(7, "", "1000 0 d0 0 0 100 100 re f")
            pdf.stream(8, "", "1000 0 d0 20000 20000 5000 5000 re f")
        }, fonts: "/F2 6 0 R")
        _ = try RedactionKit.checkFlattened(document, [RedactionMark.fromRect(0, PdfRect(240, 240, 310, 310))], [])
    }

    func test_type3FontMatrixWithSevenNumbersMakesAPicture() throws {
        let document = try RedactionFiles.open("BT /F2 10 Tf 50 50 Td (a) Tj ET", "", { pdf in
            pdf.obj(6, self.type3("97 /a", "[0.001 0 0 0.001 0 0 0]"))
            pdf.stream(7, "", "1000 0 d0 0 0 100 100 re f")
            pdf.stream(8, "", "1000 0 d0 0 0 100 100 re f")
        }, fonts: "/F2 6 0 R")
        _ = try RedactionKit.checkFlattened(document, [RedactionMark.fromRect(0, PdfRect(400, 400, 500, 500))], [])
    }

    func test_type3GlyphThatIsOnlyAHairlineIsStillInk() throws {
        let document = try RedactionFiles.open("BT /F2 10 Tf 50 50 Td (a) Tj ET", "", { pdf in
            pdf.obj(6, self.type3("97 /a"))
            pdf.stream(7, "", "1000 0 d0 0 w 20000 20000 m 25000 20000 l S")
            pdf.stream(8, "", "1000 0 d0 0 0 1 1 re f")
        }, fonts: "/F2 6 0 R")
        _ = try RedactionKit.checkFlattened(document, [RedactionMark.fromRect(0, PdfRect(200, 240, 320, 260))], [])
    }
}
