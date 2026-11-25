import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactEmptiedCellTests.cs: the same cases. A cell or mask group that holds a
// picture or text and is painted under a mark makes the page a picture; one a page without marks paints stays.

final class RedactEmptiedCellTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let group = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group << /S /Transparency /CS /DeviceGray >> /Resources <</XObject <</Im1 9 0 R>>>>"
    private let twoFills = "/Pattern cs /P1 scn 0 0 600 800 re f 10 10 5 5 re f"
    private let hole = PdfRect(200, 200, 300, 300)

    private func redact(_ document: PdfDocument) throws -> RedactionResult { try RedactionKit.apply(document, [RedactionMark.fromRect(0, hole)]) }

    private func cell(_ resources: String) -> String {
        "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 800] /XStep 600 /YStep 800 /Resources <<\(resources)>>"
    }

    func test_patternCellWhosePictureIsInASoftMaskGroupIsEmptied() throws {
        let document = try RedactionKit.page(twoFills, "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, self.cell("/ExtGState <</G 7 0 R>>"), "/G gs 0 0 600 800 re f")
            pdf.obj(7, "<</Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 8 0 R >> >>")
            pdf.stream(8, self.group, "q 100 0 0 100 100 100 cm /Im1 Do Q")
            pdf.stream(9, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_patternCellTooLongToReadIsEmptied() throws {
        let document = try RedactionKit.page(twoFills, "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, self.cell("/XObject <</Im1 7 0 R>>"), String(repeating: "n ", count: 1_000_010) + "/Im1 Do")
            pdf.stream(7, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_softMaskWithoutAnSKeyIsEmptied() throws {
        let document = try RedactionKit.page("/GS1 gs 0 0 600 800 re f 10 10 5 5 re f", "/ExtGState <</GS1 6 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /SMask << /Type /Mask /G 7 0 R >> >>")
            pdf.stream(7, self.group.replacingOccurrences(of: "9 0 R", with: "8 0 R"), "q 100 0 0 100 100 100 cm /Im1 Do Q")
            pdf.stream(8, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_meshShadingPatternWithAnotherUseIsEmptied() throws {
        let document = try RedactionKit.page(twoFills, "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.obj(6, "<</PatternType 2 /Shading 7 0 R>>")
            pdf.stream(7, "/ShadingType 4 /ColorSpace /DeviceGray /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 600 0 800 0 1]", "ZQXMESHDATAZQXMESHDATA")
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMESHDATA"))
    }

    func test_pictureAPageWithoutMarksStillPaintsStays() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 9 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources 9 0 R>>")
        pdf.stream(5, "", "q 60 0 0 60 210 210 cm /Im1 Do Q /Pattern cs /P1 scn 220 220 30 30 re f")
        pdf.stream(6, "", "/Pattern cs /P1 scn 10 10 20 20 re f")
        pdf.obj(9, "<</XObject <</Im1 8 0 R>> /Pattern <</P1 10 0 R>>>>")
        pdf.stream(8, imageEntries, pixels)
        pdf.stream(10, cell("/XObject <</Im1 8 0 R>>"), "q 50 0 0 50 0 0 cm /Im1 Do Q")
        let document = try PdfDocument.open(pdf.finish())
        let result = try redact(document)
        XCTAssertTrue(result.report.flattened.contains(0))
        // The page without marks still paints the cell and the picture in it.
        XCTAssertTrue(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }
}
