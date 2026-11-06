import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactOverlayTests.cs: the same cases. The Turkish overlay is embedded from the
// synthetic font of the annotation tests, where the C# uses Arial.

final class RedactOverlayTests: XCTestCase {
    private let box = PdfRect(100, 690, 300, 720)

    private func shown(_ result: RedactionResult) throws -> String {
        RedactionKit.text(try RedactionKit.open(result))
    }

    func test_coverIsDrawnInTheFillColourAndCarriesTheText() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, box, [1, 0, 0], "(b)(6)")])
        XCTAssertEqual(try shown(result), "(b)(6)")
        let output = try PdfDocument.open(result.bytes)
        let recorder = try ContentTestPdf.run(output)
        XCTAssertEqual(recorder.paths.count, 1)
        XCTAssertEqual(recorder.paths[0].path.bounds, box)
        XCTAssertEqual(recorder.paths[0].state.fillColor.components, [1.0, 0, 0])
        XCTAssertEqual(RedactionKit.text(output), "(b)(6)")
    }

    func test_optionsGiveTheDefaultsAndTextOnDarkIsWhite() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET")
        var options = RedactionOptions()
        options.fill = [0.1]
        options.overlayText = "REDACTED"
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, box)], options)
        let output = try RedactionKit.open(result)
        let recorder = try ContentTestPdf.run(output)
        XCTAssertEqual(recorder.paths[0].state.fillColor.components[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(RedactionKit.text(output), "REDACTED")
        XCTAssertTrue(try RedactionKit.latin(output).contains("1 g"))
    }

    func test_repeatedOverlayFillsTheWidth() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET")
        var options = RedactionOptions()
        options.overlayText = "(b)(6)"
        options.repeatOverlay = true
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(100, 690, 400, 720))], options)
        let output = try RedactionKit.open(result)
        let text = RedactionKit.text(output)
        XCTAssertTrue(text.components(separatedBy: "(b)(6)").count > 3, text)
        for g in RedactionKit.glyphs(output) { XCTAssertTrue(g.x >= 100 && g.x <= 400) }
    }

    func test_longOverlayShrinksToFit() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET")
        var options = RedactionOptions()
        options.overlayText = "PRIVILEGED AND CONFIDENTIAL"
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(100, 690, 180, 720))], options)
        let output = try RedactionKit.open(result)
        let glyphs = RedactionKit.glyphs(output)
        XCTAssertEqual(RedactionKit.text(glyphs), "PRIVILEGED AND CONFIDENTIAL")
        let last = try XCTUnwrap(glyphs.last)
        XCTAssertTrue(last.x >= 100 && last.x <= 180)
    }

    func test_turkishOverlayIsEmbeddedFromTheFontSource() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET")
        var options = RedactionOptions()
        options.overlayText = "G\u{130}Z\u{130}L\u{130} \u{15E}\u{130}\u{130}R"
        let result = try PdfRedactor(document, try AnnotationFixtures.ArialSource()).apply([RedactionMark.fromRect(0, PdfRect(100, 690, 300, 720))], options)
        XCTAssertEqual(try shown(result), "G\u{130}Z\u{130}L\u{130} \u{15E}\u{130}\u{130}R")
    }

    func test_noFontForTheOverlayIsAnErrorAndChangesNothing() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (secret words) Tj ET")
        let redactor = PdfRedactor(document)
        var options = RedactionOptions()
        options.overlayText = "G\u{130}Z\u{130}L\u{130}"
        XCTAssertThrowsError(try redactor.apply([RedactionMark.fromRect(0, box)], options)) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, RedactionText.noFont)
        }
        XCTAssertEqual(RedactionKit.text(document), "secret words")
    }

    func test_aRotatedQuadIsCoveredAndItsTextTurns() throws {
        let document = try RedactionKit.page("q 0 1 -1 0 300 100 cm BT /F1 12 Tf 0 0 Td (rotated secret) Tj ET Q")
        let marks = try RedactionKit.marksOf(document, 0, "secret").map { m -> RedactionMark in
            var turned = m
            turned.overlayText = "X-1"
            return turned
        }
        let result = try PdfRedactor(document).apply(marks)
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "rotated X-1")
        let glyphs = RedactionKit.glyphs(output)
        // The overlay runs up the page like the text it covers.
        XCTAssertTrue(glyphs[glyphs.count - 1].y > glyphs[glyphs.count - 3].y)
    }
}
