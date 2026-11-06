import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactLeftoverFormTests.cs: the same cases. What a form that was cut or copied
// leaves behind: the pictures it painted, and an original that is still painted out of sight.

final class RedactLeftoverFormTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let shows = "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET"
    private let near = PdfRect(90, 90, 200, 120)

    private func form(_ resources: String) -> String { "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> \(resources)>>" }

    private func redact(_ document: PdfDocument) throws -> RedactionResult { try RedactionKit.apply(document, [RedactionMark.fromRect(0, near)]) }

    func test_pictureOfAFormThatGoesWholeIsTakenOutOfTheListThatNamesIt() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R /Im1 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", "q 100 0 0 100 100 100 cm /Im1 Do Q /Fm Do")
            pdf.stream(7, self.imageEntries, self.pixels)
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }

    func test_formPaintedAgainOffThePageMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Fm Do q 1 0 0 1 5000 0 cm /Fm Do Q", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form(""), self.shows)
        }
        try RedactionKit.assertFlattened(document, near, "ZQXCYCLE")
    }

    func test_formPaintedAgainByATilingCellMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Fm Do /Pattern cs /P1 scn 300 300 5 5 re f", "/XObject <</Fm 6 0 R>> /Pattern <</P1 7 0 R>>") { pdf in
            pdf.stream(6, self.form(""), self.shows)
            pdf.stream(7, "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources <</XObject <</Fm 6 0 R>>>>", "/Fm Do")
        }
        try RedactionKit.assertFlattened(document, near, "ZQXCYCLE")
    }

    func test_formPaintedAgainInPlainViewMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Fm Do q 1 0 0 1 300 300 cm /Fm Do Q", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form(""), self.shows)
        }
        try RedactionKit.assertFlattened(document, near, "ZQXCYCLE")
    }

    func test_formNothingPaintsIsEmptiedWithTheText() throws {
        let document = try RedactionKit.page(shows, "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form(""), "BT /F1 12 Tf 10 10 Td [(ZQX) -1 (CYCLE)] TJ ET")
        }
        let result = try redact(document)
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "CYCLE"))
    }

    func test_verifyReadsTheTextAFormNothingPaintsWouldShow() throws {
        let document = try RedactionKit.page(shows, "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form(""), "BT /F1 12 Tf 10 10 Td [(ZQX) -1 (CYCLE)] TJ ET")
        }
        XCTAssertFalse(PdfRedactor.verify(try document.saveRewrite(), [], ["ZQXCYCLE"]).isClean)
    }
}
