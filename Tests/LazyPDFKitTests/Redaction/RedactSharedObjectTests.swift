import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactSharedObjectTests.cs: the same cases. Objects that a cut leaves behind:
// glyph procedures, resource lists inside fonts, references from other objects, keys copied along.

final class RedactSharedObjectTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let other = "ZQXOTHERDATAZQXOTHERDATAZQXOTHERDATAZQXOTHERDATAZQXOTHERDATA1234"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let type3 = "/Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.1 0 0 0.1 0 0] /Encoding <</Type /Encoding /Differences [97 /a /b]>> /FirstChar 97 /LastChar 98 /Widths [10 10]"
    private let under = PdfRect(95, 95, 125, 125)

    private func redact(_ document: PdfDocument, _ mark: PdfRect? = nil) throws -> RedactionResult {
        try RedactionKit.apply(document, [RedactionMark.fromRect(0, mark ?? under)])
    }

    func test_fontWhoseGlyphPaintsAPictureMakesThePagePicture() throws {
        let document = try RedactionKit.page("BT /F3 12 Tf 100 100 Td (a) Tj 200 0 Td (b) Tj ET", "/Font <</F3 6 0 R>>") { pdf in
            pdf.obj(6, "<<\(self.type3) /CharProcs <</a 7 0 R /b 8 0 R>> /Resources <</XObject <</Im1 9 0 R>>>>>>")
            pdf.stream(7, "", "10 0 d0 q 8 0 0 8 0 0 cm /Im1 Do Q")
            pdf.stream(8, "", "10 0 d0 0 0 5 5 re f")
            pdf.stream(9, self.imageEntries, self.pixels)
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, under)], "ZQXPIXELSDATA")
    }

    func test_pictureListedInAType3FontHeldDirectlyIsNotLeftBehind() throws {
        let document = try ContentTestPdf.page("q 30 0 0 30 100 100 cm /Im1 Do Q",
            "/Font <</F1 5 0 R /F3 <<\(type3) /CharProcs <</a 7 0 R>> /Resources <</XObject <</Im1 6 0 R>>>>>>>> /XObject <</Im1 6 0 R>>") { pdf in
            pdf.obj(5, RedactionKit.helvetica)
            pdf.stream(6, self.imageEntries, self.pixels)
            pdf.stream(7, "", "10 0 d0 0 0 5 5 re f")
        }
        let result = try redact(document, PdfRect(95, 95, 135, 135))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_alternateImageNamingACutOriginalDoesNotKeepIt() throws {
        let document = try RedactionKit.page("q 30 0 0 30 100 100 cm /Im1 Do Q q 20 0 0 20 400 400 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 7 0 R>>") { pdf in
            pdf.stream(6, self.imageEntries, self.pixels)
            pdf.stream(7, "\(self.imageEntries) /Alternates [<</Image 6 0 R /DefaultForPrinting true>>]", self.other)
        }
        let result = try redact(document, PdfRect(95, 95, 135, 135))
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
        XCTAssertTrue(RedactionKit.holds(result.bytes, "ZQXOTHERDATA"))
    }

    func test_cutImageDoesNotKeepAnAttachedFileOrAnyOtherReference() throws {
        let document = try RedactionKit.page("q 30 0 0 30 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "\(self.imageEntries) /AF [<</Type /Filespec /F (source.png) /EF <</F 7 0 R>>>>] /Measure <</Subtype /RL /R (ZQXMEASURE)>>", self.pixels)
            pdf.stream(7, "/Type /EmbeddedFile", "ZQXSOURCEFILE")
        }
        let result = try redact(document, PdfRect(95, 95, 135, 135))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSOURCEFILE"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMEASURE"))
    }

    func test_copiedFormDoesNotKeepAnAttachedFile() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>> /AF [<</Type /Filespec /F (source.txt) /EF <</F 7 0 R>>>>]",
                       "BT /F1 12 Tf 100 100 Td (ZQXFORMTEXT) Tj ET")
            pdf.stream(7, "/Type /EmbeddedFile", "ZQXSOURCEFILE")
        }
        let result = try redact(document, PdfRect(90, 90, 200, 120))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXFORMTEXT"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSOURCEFILE"))
    }
}
