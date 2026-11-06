import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeStripTests.cs: the same cases. The PdfPig text assertion of
// UnusedResourcesAreDropped has no twin; the engine's own text stands in for it.

final class OptimizeStripTests: XCTestCase {
    private let thumb = "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8"

    func test_thumbnailsAndApplicationDataGo() throws {
        let file = OptimizeKit.build("0 0 10 10 re f", "", { pdf in
            pdf.stream(5, self.thumb, Array(repeating: 0, count: 16))
            pdf.obj(6, "<</Photo <</LastModified (D:20200101000000Z) /Private 7 0 R>>>>")
            pdf.stream(7, "", "MARKERPIECE")
        }, pageExtra: "/Thumb 5 0 R /PieceInfo 6 0 R", catalogExtra: "/PieceInfo 6 0 R /ADBE_Private (MARKERPRIVATE)")
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.stripThumbnails = true; $0.stripPieceInfo = true; $0.stripPrivateData = true })
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERPIECE"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERPRIVATE"))
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(0, OptimizeKit.count(after) { OptimizeKit.isImage(after, $0) })
        XCTAssertNil(after.pages[0].dictionary["Thumb"])
        XCTAssertTrue(result.sizeAfter < result.sizeBefore)
    }

    func test_applicationDataStaysWhenNotAsked() throws {
        let file = OptimizeKit.build("0 0 10 10 re f", "", { pdf in pdf.stream(7, "", "MARKERPIECE") }, pageExtra: "/PieceInfo <</X 7 0 R>>")
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off)
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "MARKERPIECE"))
    }

    func test_unusedResourcesAreDropped() throws {
        let resources = "/Font <</F1 5 0 R /F2 6 0 R>> /XObject <</Fm0 7 0 R /Fm1 8 0 R>> /ExtGState <</G0 <</CA 0.5>>>>"
        let file = OptimizeKit.build("BT /F1 12 Tf 10 100 Td (kept) Tj ET /G0 gs q /Fm0 Do Q", resources, { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
            pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /UnusedMarkerFont>>")
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</Font <</F3 9 0 R /F4 6 0 R>>>>", "BT /F3 8 Tf (inner) Tj ET")
            pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 0 5 5 re f")
            pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>")
        })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.pruneResources = true })
        let after = try PdfDocument.open(result.bytes)
        let page = try XCTUnwrap(after.pages[0].resources)
        XCTAssertEqual(true, after.dict(page, "Font")?.containsKey("F1"))
        XCTAssertEqual(false, after.dict(page, "Font")?.containsKey("F2"))
        XCTAssertEqual(true, after.dict(page, "XObject")?.containsKey("Fm0"))
        XCTAssertEqual(false, after.dict(page, "XObject")?.containsKey("Fm1"))
        let form = try XCTUnwrap(after.resolve(after.dict(page, "XObject")?["Fm0"]) as? PdfStream)
        let inner = try XCTUnwrap(after.dict(after.dict(form.dictionary, "Resources"), "Font"))
        XCTAssertTrue(inner.containsKey("F3"))
        XCTAssertFalse(inner.containsKey("F4"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "UnusedMarkerFont"))
        XCTAssertTrue(try OptimizeKit.engineText(result.bytes).contains("kept"))
    }

    func test_sharedResourcesKeepWhatEitherPageUses() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200] /Resources 7 0 R>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>")
        pdf.stream(5, "", "BT /F1 12 Tf (one) Tj ET")
        pdf.stream(6, "", "BT /F2 12 Tf (two) Tj ET")
        pdf.obj(7, "<</Font <</F1 8 0 R /F2 9 0 R /F3 10 0 R>>>>")
        pdf.obj(8, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.obj(9, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>")
        pdf.obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Times-Roman>>")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.pruneResources = true })
        let after = try PdfDocument.open(result.bytes)
        let fonts = try XCTUnwrap(after.dict(after.pages[0].resources, "Font"))
        XCTAssertTrue(fonts.containsKey("F1"))
        XCTAssertTrue(fonts.containsKey("F2"))
        XCTAssertFalse(fonts.containsKey("F3"))
    }

    func test_resourcesOfAPageWithUnreadableContentAreKept() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents [4 0 R 5 0 R] /Resources <</Font <</F1 6 0 R /F2 6 0 R>>>>>>")
        pdf.stream(4, "", "BT /F1 12 Tf (a) Tj ET")
        pdf.stream(5, "/Filter /ASCIIHexDecode", "zz not hex")
        pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.pruneResources = true })
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(true, after.dict(after.pages[0].resources, "Font")?.containsKey("F2"))
    }
}
