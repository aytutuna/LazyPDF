import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextReviewTests.cs: the same cases. XCTest has no per-test timeout in the
// first case, so a hang there ends the run at the job's.

final class TextReviewTests: TextTestCase {
    func test_notANumberGlyphEdgeDoesNotHangTheColumnScan() throws {
        let content = line(100, 700, "left") + line(300, 700, "right")
            + "BT /F1 10 Tf 1 0 0 \(TextTestPdf.big(306)) 100 100 Tm (x) Tj ET\n"
        let page = try text(content, "/UserUnit 1000")
        XCTAssertTrue(page.text.contains("left"))
    }

    func test_glyphsWhoseEmOverflowDoNotHangTheLineJoin() throws {
        let bbox = "318" + String(repeating: "0", count: 155)
        let big150 = TextTestPdf.big(150), far = TextTestPdf.big(300)
        let content = "BT /F1 1 Tf 1 -1 \(big150) \(big150) \(far) \(far) Tm (a) Tj ET\n"
            + "BT /F2 10 Tf 1 -1 1 1 100 700 Tm (b) Tj ET\n"
            + "BT /F1 1 Tf 1 -1 \(big150) \(big150) -\(far) -\(far) Tm (c) Tj ET\n"
        let document = try page(content, "/Font <</F1 5 0 R /F2 7 0 R>>", "/UserUnit 2") { pdf in
            self.font(pdf, 7)
            pdf.obj(5, "<</Type /Font /Subtype /Type3 /FontBBox [0 -\(bbox) 8 \(bbox)] /FontMatrix [1 0 0 1 0 0] /FirstChar 97 /LastChar 99 "
                + "/Widths [6 6 6] /Encoding <</Type /Encoding /Differences [97 /a /b /c]>> /CharProcs <</a 6 0 R /b 6 0 R /c 6 0 R>>>>")
            pdf.stream(6, "", "6 0 0 -2 6 6 d1 0 0 6 6 re f")
        }
        let result = TextPage.create(document, document.pages[0])
        XCTAssertTrue(result.text.contains("b"))
        XCTAssertNil(TextInvariants.check(result))
    }

    func test_loneSurrogateInAMapDoesNotBreakThePage() throws {
        let document = try TextTestPdf.page(line(100, 700, "A"), "/Font <</F1 5 0 R>>", "") { pdf in
            TextTestPdf.font(pdf, 5, units: [(65, [0xD800, 0xFB01])])
        }
        let page = TextPage.create(document, document.pages[0])
        XCTAssertEqual(page.chars.count, 1)
    }

    func test_shearedTextStaysOneLine() throws {
        let page = try text("BT /F1 10 Tf 1 0 0.3 1 100 700 Tm (hello world, in italic) Tj ET")
        XCTAssertEqual(page.text, "hello world, in italic")
        XCTAssertEqual(page.lines.count, 1)
    }

    func test_narrowRepeatedLettersAreNotDuplicates() throws {
        let page = try text("BT /F1 10 Tf 30 Tz 100 700 Td (Hello million) Tj ET")
        XCTAssertEqual(page.text, "Hello million")
    }

    func test_actualTextIsDecodedAsPdfDocEncoding() throws {
        let page = try text(#"/Span <</ActualText (\204)>> BDC BT /F1 10 Tf 100 700 Td (-) Tj ET EMC"#)
        XCTAssertEqual(page.text, "\u{2014}")
    }

    func test_type3GlyphsKeepTheirOwnSize() throws {
        let widths = (32..<99).map { $0 == 32 ? "3" : "6" }.joined(separator: " ")
        let document = try self.page("BT /F1 1 Tf 100 700 Td (ab ab) Tj ET", "/Font <</F1 5 0 R>>", "") { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type3 /FontBBox [0 -2 8 6] /FontMatrix [1 0 0 1 0 0] /FirstChar 32 /LastChar 98 "
                + "/Widths [" + widths + "] "
                + "/Encoding <</Type /Encoding /Differences [32 /space 97 /a /b]>> /CharProcs <</a 6 0 R /b 6 0 R /space 6 0 R>>>>")
            pdf.stream(6, "", "6 0 0 -2 6 6 d1 0 0 6 6 re f")
        }
        let result = TextPage.create(document, document.pages[0])
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.chars[0].quad.bounds.height > 5)
    }

    func test_percentSignStaysWithItsNumberInRightToLeftText() throws {
        // Visual order: 50% to the left of an Hebrew letter.
        let page = try text(line(100, 700, #"50%\001"#), "", (1, "\u{05D0}"))
        XCTAssertTrue(page.text.replacingOccurrences(of: "\u{05D0}", with: "").trimmingCharacters(in: .whitespaces).hasSuffix("50%"))
        XCTAssertTrue(page.text.contains("50%"))
    }

    func test_wholeWordSearchFindsAMatchOverlappingARejectedOne() throws {
        let page = try text(line(100, 700, "xab ab ab"))
        let hits = try TextSearch.find(page, "ab ab", TextSearchOptions(wholeWord: true))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].range.start, 4)
    }

    func test_regexPatternIsFoldedWithThePage() throws {
        let page = try text(line(100, 700, #"\001ehir"#), "", (1, "\u{15F}"))
        let options = TextSearchOptions(regex: true, foldDiacritics: true)
        XCTAssertEqual(try TextSearch.find(page, "\\b\u{15F}ehir\\b", options).count, 1)
    }

    func test_dottedCapitalIMatchesPlainI() throws {
        let page = try text(line(100, 700, #"\001STANBUL"#), "", (1, "\u{130}"))
        XCTAssertEqual(try TextSearch.find(page, "istanbul").count, 1)
    }
}
