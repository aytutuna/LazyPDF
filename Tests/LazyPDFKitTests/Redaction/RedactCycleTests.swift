import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactCycleTests.cs: the same cases. The interpreter skips a form that is
// already being run, so what a form that reaches itself shows is never looked at: the page becomes a picture.

final class RedactCycleTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let near = PdfRect(90, 90, 200, 120)

    private func form(_ resources: String) -> String { "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> \(resources)>>" }

    func test_formThatPaintsItselfGoesWholeWhereItMeetsAMark() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/XObject <</Fm 6 0 R>>"), "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET q 1 0 0 1 5000 0 cm /Fm Do Q")
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXCYCLE")
    }

    func test_formsThatPaintEachOtherGoWholeWhereTheyMeetAMark() throws {
        let document = try RedactionKit.page("/A Do", "/XObject <</A 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/XObject <</B 7 0 R>>"), "BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET q 1 0 0 1 5000 0 cm /B Do Q")
            pdf.stream(7, self.form("/XObject <</A 6 0 R>>"), "q 1 0 0 1 0 5000 cm /A Do Q")
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXCYCLE")
    }

    func test_imageInAFormThatPaintsItselfIsNotLeftUncut() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/XObject <</Fm 6 0 R /Im1 7 0 R>>"), "q 30 0 0 30 100 100 cm /Im1 Do Q q 1 0 0 1 5000 0 cm /Fm Do Q")
            pdf.stream(7, self.imageEntries, self.pixels)
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXPIXELSDATA")
    }

    func test_formThatPaintsItselfAwayFromTheMarksMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Fm Do BT /F1 12 Tf 100 100 Td (ZQXGONE) Tj ET", "/XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, self.form("/XObject <</Fm 6 0 R>>").replacingOccurrences(of: "[0 0 600 800]", with: "[250 250 400 400]"),
                       "BT /F1 12 Tf 300 300 Td (ZQXKEPT) Tj ET q 1 0 0 1 5000 0 cm /Fm Do Q")
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, near)], "ZQXGONE", "ZQXKEPT")
    }
}
