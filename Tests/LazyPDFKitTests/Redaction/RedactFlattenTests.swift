import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactFlattenTests.cs: the same cases. A page the redaction cannot follow
// becomes one picture: drawn from the file as it stands, the marks filled in the pixels.

final class RedactFlattenTests: XCTestCase {
    private let loop = "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET /Fm Do"
    private let near = PdfRect(90, 90, 200, 120)

    // A form that paints itself is read differently from how a viewer draws it, which is what makes a page not understood.
    private func looping(_ extra: String = "", page: String? = nil) throws -> PdfDocument {
        try RedactionKit.page(page ?? loop, "/XObject <</Fm 6 0 R>>" + extra) { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</Fm 6 0 R>>>>", "/Fm Do")
        }
    }

    // Samples of the picture of the page: RGB, top row first.
    private func picture(_ output: PdfDocument, _ page: Int = 0) throws -> (samples: [UInt8], width: Int, height: Int) {
        let images = RedactionKit.images(output, page)
        XCTAssertEqual(images.count, 1)
        let image = try XCTUnwrap(images.first)
        let stream = try XCTUnwrap(image.stream)
        XCTAssertEqual(output.name(stream.dictionary, "ColorSpace"), "DeviceRGB")
        return (try output.data(stream), image.width, image.height)
    }

    private func pixel(_ picture: (samples: [UInt8], width: Int, height: Int), _ column: Double, _ row: Double) -> [UInt8] {
        let i = (Int(row) * picture.width + Int(column)) * 3
        return Array(picture.samples[i..<(i + 3)])
    }

    func test_markIsFilledInThePixelsAndTheRestIsTheRenderedPage() throws {
        let document = try looping()
        let result = try RedactionKit.assertFlattened(document, near, "ZQXCYCLE")
        let output = try RedactionKit.reopen(result.bytes)
        let flat = try picture(output)
        let scale = Double(flat.width) / 600.0
        XCTAssertEqual(pixel(flat, 145 * scale, (800 - 105) * scale), [0, 0, 0])
        XCTAssertNotEqual(pixel(flat, 400 * scale, 400 * scale), [0, 0, 0])
    }

    func test_markFillColourIsUsedInThePixels() throws {
        let document = try looping()
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, near, [1, 0, 0])])
        let output = try RedactionKit.reopen(result.bytes)
        let flat = try picture(output)
        let scale = Double(flat.width) / 600.0
        XCTAssertEqual(pixel(flat, 145 * scale, (800 - 105) * scale), [255, 0, 0])
    }

    func test_pageIsDrawnAtTheDpiOfTheOptionsAndAt200ByDefault() throws {
        let document = try looping()
        let renderer = RedactFakeRenderer(document)
        var options = RedactionOptions()
        options.renderer = renderer
        _ = try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)], options)
        options.flattenDpi = 36
        _ = try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)], options)
        XCTAssertEqual(renderer.dpis, [200, 36])
    }

    func test_flattenMarkedPagesDrawsAPageThatWasUnderstood() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (ZQXMARKER) Tj ET")
        let marks = try RedactionKit.marksOf(document, 0, "ZQXMARKER")
        XCTAssertTrue(try PdfRedactor(document).apply(marks, RedactionKit.drawing(document)).report.flattened.isEmpty)
        var options = RedactionOptions()
        options.flattenMarkedPages = true
        let result = try PdfRedactor(document).apply(marks, RedactionKit.drawing(document, options))
        XCTAssertEqual(result.report.flattened, [0])
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMARKER"))
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertFalse(try RedactionKit.latin(output).contains("Tj"))
    }

    func test_flattenMarkedPagesWithoutARendererIsRefused() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (ZQXMARKER) Tj ET")
        let marks = try RedactionKit.marksOf(document, 0, "ZQXMARKER")
        var options = RedactionOptions()
        options.flattenMarkedPages = true
        XCTAssertThrowsError(try PdfRedactor(document).apply(marks, options)) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, RedactionText.needsPicture(0))
        }
    }

    func test_dpiOutOfRangeIsRefused() throws {
        for dpi in [0.0, -5, 5000] {
            let document = try looping()
            var options = RedactionOptions()
            options.renderer = RedactFakeRenderer(document)
            options.flattenDpi = dpi
            XCTAssertThrowsError(try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)], options), "\(dpi)") { XCTAssertTrue($0 is ArgumentException) }
        }
    }

    func test_rotatedPageKeepsItsBoxesAndTurnAndTheMarkStaysWhereItWas() throws {
        let document = try looping(page: "/Fm Do BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET")
        let page = document.pages[0].dictionary
        page["Rotate"] = PdfNumber(90)
        page["CropBox"] = PdfRect(20, 30, 520, 700).toArray()
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, near)])
        let output = try RedactionKit.reopen(result.bytes)
        let flat = output.pages[0]
        XCTAssertEqual(flat.rotate, 90)
        XCTAssertEqual(flat.cropBox, PdfRect(20, 30, 520, 700))
        XCTAssertEqual(flat.mediaBox, document.pages[0].mediaBox)
        let shown = try picture(output)
        let geometry = PageGeometry(flat)
        let (x, y) = geometry.toDisplay(145, 105)
        XCTAssertEqual(pixel(shown, x * Double(shown.width) / geometry.width, y * Double(shown.height) / geometry.height), [0, 0, 0])
    }

    func test_oldContentResourcesAndPageExtrasAreGone() throws {
        let document = try looping("/Properties <</P0 <</Alt (ZQXPROPS)>>>>")
        let page = document.pages[0].dictionary
        let piece = PdfDictionary()
        piece["App"] = PdfText.toObject("ZQXPIECE")
        page["PieceInfo"] = piece
        let group = PdfDictionary()
        group["S"] = PdfName("Transparency")
        page["Group"] = group
        page["Foo"] = PdfText.toObject("ZQXEXTRA")
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, near)])
        XCTAssertTrue(result.report.flattened.contains(0))
        for word in ["ZQXCYCLE", "ZQXPROPS", "ZQXPIECE", "ZQXEXTRA"] { XCTAssertFalse(RedactionKit.holds(result.bytes, word), word) }
        let output = try RedactionKit.reopen(result.bytes)
        let flat = output.pages[0].dictionary
        let keys = flat.entries.map { $0.key }.filter { $0 != "MediaBox" }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        XCTAssertEqual(keys, ["Contents", "Parent", "Resources", "Type"])
    }

    func test_annotationsAndFieldsLeaveAPageThatBecamePicture() throws {
        let document = try looping()
        try PdfAnnotationWriter(document).addLink(document.pages[0], PdfRect(300, 300, 400, 320), UriAction("https://example.com/ZQXLINK") as PdfAction)
        try PdfForm.read(document).addField(FieldSpec(.text, "name", 0, PdfRect(300, 400, 400, 420), value: "ZQXVALUE"))
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, near)])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(PdfAnnotations.read(output, output.pages[0]).isEmpty)
        XCTAssertNil(output.dict(output.catalog, "AcroForm"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXLINK"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXVALUE"))
        XCTAssertEqual(result.report.fields, 1)
    }

    func test_overlayTextIsDrawnAsTextOnTheFlattenedPage() throws {
        let document = try looping()
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, near, nil, "X-1")])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "X-1")
    }

    func test_withoutARendererTheCallRefusesAndNamesThePage() throws {
        let document = try looping()
        XCTAssertThrowsError(try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)])) { error in
            let message = (error as? InvalidOperationException)?.message
            XCTAssertEqual(message, RedactionText.needsPicture(0))
            XCTAssertTrue(message?.contains("Page 1") ?? false)
        }
    }

    func test_refusalNamesTheFirstPageThatNeedsAPicture() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 8 0 R] /Count 3 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>> /XObject <</Fm 9 0 R>>>>>>")
        pdf.obj(8, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>> /XObject <</Fm 9 0 R>>>>>>")
        pdf.stream(5, "", "BT /F1 12 Tf 100 100 Td (ZQXFINE) Tj ET")
        pdf.stream(6, "", loop)
        pdf.obj(7, RedactionKit.helvetica)
        pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</Fm 9 0 R>>>>", "/Fm Do")
        let document = try PdfDocument.open(pdf.finish())
        let marks = [0, 1, 2].map { RedactionMark.fromRect($0, near) }
        XCTAssertThrowsError(try PdfRedactor(document).apply(marks)) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, RedactionText.needsPicture(1))
        }

        let result = try RedactionKit.apply(document, marks)
        XCTAssertEqual(result.report.flattened, [1, 2])
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output, 0), "")
        XCTAssertEqual(RedactionKit.images(output, 1).count, 1)
    }

    private final class NoRenderer: PageRenderer {
        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
    }

    func test_rendererThatCannotDrawThePageRefuses() throws {
        let document = try looping()
        var options = RedactionOptions()
        options.renderer = NoRenderer()
        XCTAssertThrowsError(try PdfRedactor(document).apply([RedactionMark.fromRect(0, near)], options)) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, RedactionText.notDrawn(0))
        }
    }

    func test_reportSaysInPlainWordsWhichPagesAreNoLongerText() throws {
        let document = try looping()
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, near)])
        XCTAssertEqual(result.report.flattened, [0])
        XCTAssertTrue(result.report.description.contains("Page 1 was turned into a picture. Its text can no longer be selected."))
        XCTAssertFalse(result.report.description.contains("Nothing was under the marks"))
    }

    func test_ordinaryPageIsRedactedAsTextAndNeverDrawn() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (ZQXCYCLE kept) Tj ET")
        let renderer = RedactFakeRenderer(document)
        var options = RedactionOptions()
        options.renderer = renderer
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXCYCLE"), options)
        XCTAssertTrue(renderer.drawn.isEmpty)
        XCTAssertTrue(result.report.flattened.isEmpty)
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output).trimmingCharacters(in: .whitespaces), "kept")
    }

    func test_pageWithoutMarksIsNotDrawn() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>> /XObject <</Fm 9 0 R>>>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>")
        pdf.stream(5, "", loop)
        pdf.stream(6, "", "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET")
        pdf.obj(7, RedactionKit.helvetica)
        pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</Fm 9 0 R>>>>", "/Fm Do")
        let document = try PdfDocument.open(pdf.finish())
        let renderer = RedactFakeRenderer(document)
        let marks = try RedactionKit.marksOf(document, 1, "ZQXCYCLE")
        var options = RedactionOptions()
        options.renderer = renderer
        let result = try PdfRedactor(document).apply(marks, options)
        XCTAssertTrue(renderer.drawn.isEmpty)
        XCTAssertTrue(result.report.flattened.isEmpty)
    }
}
