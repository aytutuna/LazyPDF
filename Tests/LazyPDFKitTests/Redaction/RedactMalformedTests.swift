import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactMalformedTests.cs: the same cases.

final class RedactMalformedTests: XCTestCase {
    private let box = PdfRect(90, 690, 300, 720)

    func test_marksThatMakeNoSenseAreIgnored() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (kept) Tj ET")
        let nan = TextQuad(Double.nan, 0, 1, 0, 1, 1, 0, 1)
        let flat = TextQuad(100, 700, 200, 700, 200, 700, 100, 700)
        let result = try RedactionKit.apply(document, [
            RedactionMark(5, [TextQuad(0, 0, 1, 0, 1, 1, 0, 1)]), RedactionMark(-1, []), RedactionMark(0, []), RedactionMark(0, [nan, flat]),
        ])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "kept")
    }

    func test_noMarksIsJustARewrite() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (kept) Tj ET")
        let result = try RedactionKit.apply(document, [])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "kept")
        XCTAssertTrue(result.report.pages.isEmpty)
        XCTAssertTrue(result.report.description.contains("Nothing"))
    }

    func test_contentThatIsBroken() throws {
        let document = try RedactionKit.page("q q BT /F1 12 Tf 100 700 Td (secret) Tj Q Q Q ) ] >> 1 2 3 foo (unclosed [ (x")
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, box, nil, "X")])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "X")
    }

    func test_textObjectLeftOpenDoesNotSwallowTheCover() throws {
        let document = try RedactionKit.page("1 0 0 1 10 10 cm BT /F1 12 Tf 90 690 Td (secret) Tj")
        let marks = try RedactionKit.marksOf(document, 0, "secret")
        var options = RedactionOptions()
        options.overlayText = "X"
        let result = try RedactionKit.apply(document, marks, options)
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "X")
        let paths = try ContentTestPdf.run(output).paths
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].path.bounds, marks[0].quads[0].bounds)
    }

    func test_pageWithoutContentOrResourcesIsFine() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        let document = try PdfDocument.open(pdf.finish())
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(10, 10, 100, 100))])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(output.pages.count, 1)
    }

    func test_imageThatCannotBeDecodedIsRemovedNotLeft() throws {
        let document = try RedactionKit.page("q 100 0 0 100 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", "this is not zlib data at all")
        }
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(100, 100, 150, 150))])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(RedactionKit.images(output).isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "this is not zlib"))
    }

    func test_imageWhoseMaskIsItselfAndOneThatLiesAboutItsSizeAreSurvived() throws {
        let document = try RedactionKit.page("q 100 0 0 100 100 100 cm /Im1 Do Q q 100 0 0 100 300 100 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 6 0 R", "abcd")
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 8000 /Height 8000 /ColorSpace /DeviceGray /BitsPerComponent 8", "abcd")
        }
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(0, 0, 500, 300))])
        let output = try RedactionKit.open(result)
        _ = output
        XCTAssertEqual(result.report.images, 2)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "abcd"))
    }

    func test_formThatRunsIntoItselfAndImageWithoutColourSpaceMakeThePagePicture() throws {
        let document = try RedactionKit.page("/Fm1 Do q 100 0 0 100 100 100 cm /Im1 Do Q BT /F1 12 Tf 100 300 Td (loop) Tj ET", "/XObject <</Fm1 6 0 R /Im1 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</Fm1 6 0 R>>>>", "/Fm1 Do 0 0 10 10 re f")
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /BitsPerComponent 8", "abcd")
        }
        try RedactionKit.assertFlattened(document, PdfRect(0, 0, 200, 200), "loop")
    }

    func test_manyMarksOnOnePageStayFast() throws {
        let content = (0..<200).map { i in
            "BT /F1 6 Tf \(10 + i % 20 * 28) \(780 - i / 20 * 20) Td (w\(String(format: "%03d", i))x) Tj ET"
        }.joined(separator: " ")
        let document = try RedactionKit.page(content)
        let marks = try (0..<100).map { try RedactionKit.marksOf(document, 0, "w" + String(format: "%03d", $0 * 2) + "x")[0] }
        let start = Date()
        let result = try RedactionKit.apply(document, marks)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.glyphs(output).count / 5, 100)
    }
}
