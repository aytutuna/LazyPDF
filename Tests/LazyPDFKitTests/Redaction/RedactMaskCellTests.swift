import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactMaskCellTests.cs: the same cases. Soft masks, tiling cells and pictures
// that others name: under a mark a mask or a cell with more than shapes makes the page a picture, and what nothing paints is
// emptied whoever names it.

final class RedactMaskCellTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let maskPixels = "ZQXMASKBYTESZQXMASKBYTESZQXMASKBYTESZQXMASKBYTESZQXMASKBYTESZQXM123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let group = "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</XObject <</Im1 9 0 R>>>>"
    private let twoFills = "/Pattern cs /P1 scn 0 0 600 800 re f 10 10 5 5 re f"
    private let hole = PdfRect(200, 200, 300, 300)
    private let axial = "<</ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function <</FunctionType 2 /Domain [0 1] /N 1>>>>"

    private func redact(_ document: PdfDocument, _ area: PdfRect? = nil) throws -> RedactionResult {
        try RedactionKit.apply(document, [RedactionMark.fromRect(0, area ?? hole)])
    }

    private func cell(_ resources: String) -> String {
        "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 600 800] /XStep 600 /YStep 800 /Resources <<\(resources)>>"
    }

    func test_axialShadingPaintedThroughASoftMaskTakesItsPictureWithIt() throws {
        let document = try RedactionKit.page("/G gs /Sh0 sh", "/ExtGState <</G 6 0 R>> /Shading <</Sh0 7 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /SMask <</Type /Mask /S /Alpha /G 8 0 R>>>>")
            pdf.obj(7, self.axial)
            pdf.stream(8, self.group, "q 300 0 0 300 50 50 cm /Im1 Do Q")
            pdf.stream(9, self.imageEntries, self.pixels)
        }
        let result = try redact(document, PdfRect(100, 100, 300, 300))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_emptiedCellIsEmptyForEveryReferenceToIt() throws {
        let document = try RedactionKit.page(twoFills, "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, self.cell("/XObject <</Im1 7 0 R>>"), "q 50 0 0 50 0 0 cm /Im1 Do Q")
            pdf.stream(7, self.imageEntries, self.pixels)
        }
        document.catalog["Keep"] = PdfReference(6, 0)
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertTrue(try output.data(try XCTUnwrap(output.resolve(output.catalog["Keep"]) as? PdfStream)).isEmpty)
    }

    func test_emptiedMaskIsEmptyForEveryReferenceToIt() throws {
        let document = try RedactionKit.page("/GS1 gs 0 0 600 800 re f 10 10 5 5 re f", "/ExtGState <</GS1 6 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /SMask 7 0 R>>")
            pdf.obj(7, "<</Type /Mask /S /Alpha /G 8 0 R>>")
            pdf.stream(8, self.group, "q 100 0 0 100 100 100 cm /Im1 Do Q")
            pdf.stream(9, self.imageEntries, self.pixels)
        }
        document.catalog["Keep"] = PdfReference(7, 0)
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_shadingPatternWhoseOwnSoftMaskHoldsAPictureIsEmptied() throws {
        let document = try RedactionKit.page(twoFills, "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.obj(6, "<</PatternType 2 /Shading 7 0 R /ExtGState <</SMask <</Type /Mask /S /Alpha /G 8 0 R>>>>>>")
            pdf.obj(7, self.axial)
            pdf.stream(8, self.group, "q 100 0 0 100 100 100 cm /Im1 Do Q")
            pdf.stream(9, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_pictureBelowTheDepthTheInterpreterEntersStillMakesTheCellCarry() throws {
        let document = try RedactionKit.page(twoFills, "/Pattern <</P1 6 0 R>>") { pdf in
            pdf.stream(6, self.cell("/XObject <</F0 7 0 R>>"), "/F0 Do")
            for i in 0..<24 {
                let body = i < 23 ? "/F\(i + 1) Do" : "q 10 0 0 10 0 0 cm /Im1 Do Q"
                let resources = i < 23 ? "/XObject <</F\(i + 1) \(8 + i) 0 R>>" : "/XObject <</Im1 31 0 R>>"
                pdf.stream(7 + i, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <<\(resources)>>", body)
            }
            pdf.stream(31, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_masksOfACutPictureLeaveTheResourceListsThatOnlyNamedThem() throws {
        let document = try RedactionKit.page("q 100 0 0 100 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R /M1 7 0 R>>") { pdf in
            pdf.stream(6, self.imageEntries + " /SMask 7 0 R", self.pixels)
            pdf.stream(7, self.imageEntries, self.maskPixels)
        }
        let result = try redact(document, PdfRect(120, 120, 180, 180))
        XCTAssertEqual(result.report.images, 1)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMASKBYTES"))
    }

    func test_maskThatAnotherPictureStillUsesMakesAPicture() throws {
        let document = try RedactionKit.page("q 100 0 0 100 100 100 cm /Im1 Do Q q 50 0 0 50 400 400 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 8 0 R>>") { pdf in
            pdf.stream(6, self.imageEntries + " /SMask 7 0 R", self.pixels)
            pdf.stream(7, self.imageEntries, self.maskPixels)
            pdf.stream(8, self.imageEntries + " /SMask 7 0 R", self.pixels)
        }
        try RedactionKit.assertFlattened(document, PdfRect(120, 120, 180, 180))
    }

    func test_cutPictureKeepsTheMatteOfItsSoftMask() throws {
        let document = try RedactionKit.page("q 100 0 0 100 100 100 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, self.imageEntries + " /SMask 7 0 R", self.pixels)
            pdf.stream(7, self.imageEntries + " /Matte [0]", self.maskPixels)
        }
        let result = try redact(document, PdfRect(120, 120, 180, 180))
        let output = try RedactionKit.reopen(result.bytes)
        let images = RedactionKit.images(output)
        XCTAssertEqual(images.count, 1)
        let image = try XCTUnwrap(images.first?.stream)
        XCTAssertNotNil(try XCTUnwrap(output.stream(image.dictionary, "SMask")).dictionary["Matte"])
    }

    func test_formThatNothingPaintsAndShowsTheRemovedTextIsEmptied() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET", "/XObject <</Old 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET")
        }
        let result = try redact(document, PdfRect(90, 90, 200, 120))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXCYCLE"))
    }

    func test_formThatIsPaintedMayShowTheWordElsewhere() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET /Old Do", "/XObject <</Old 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 300 300 Td (ZQXCYCLE) Tj ET")
        }
        let result = try redact(document, PdfRect(90, 90, 200, 120))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        XCTAssertEqual(RedactionKit.text(try RedactionKit.reopen(result.bytes)), "ZQXCYCLE")
    }
}
