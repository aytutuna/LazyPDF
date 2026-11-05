import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextHiddenContentTests.cs: the same cases.

final class TextHiddenContentTests: XCTestCase {
    private func layered(_ off: String) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /OCProperties <</OCGs [7 0 R 8 0 R] /D <</OFF [\(off)]>>>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [10 0 R] /Count 1 /MediaBox [0 0 300 300]>>")
        pdf.obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.obj(7, "<</Type /OCG /Name (Notes)>>")
        pdf.obj(8, "<</Type /OCG /Name (Extra)>>")
        pdf.obj(9, "<</Type /OCMD /OCGs [7 0 R 8 0 R] /P /AllOn>>")
        pdf.obj(10, "<</Type /Page /Parent 2 0 R /Contents 20 0 R /Resources <</Font <</F1 3 0 R>> /Properties <</L1 7 0 R /L2 8 0 R /M 9 0 R>> /XObject <</Fm 21 0 R>>>>>>")
        pdf.stream(20, "", "BT /F1 12 Tf 20 250 Td (plain) Tj ET "
            + "/OC /L1 BDC BT /F1 12 Tf 20 200 Td (notes) Tj ET EMC "
            + "/OC /L2 BDC BT /F1 12 Tf 20 150 Td (extra) Tj ET EMC "
            + "/OC /M BDC BT /F1 12 Tf 20 100 Td (member) Tj ET EMC "
            + "/Fm Do")
        pdf.stream(21, "/Type /XObject /Subtype /Form /BBox [0 0 300 300] /OC 7 0 R /Resources <</Font <</F1 3 0 R>>>>", "BT /F1 12 Tf 20 50 Td (inform) Tj ET")
        return try PdfDocument.open(pdf.finish())
    }

    private func words(_ document: PdfDocument) -> String {
        // Ordinal order, as Enumerable.Order() on strings sorts them.
        TextPage.create(document, document.pages[0]).words.map { $0.text }
            .sorted { Array($0.unicodeScalars.map { $0.value }).lexicographicallyPrecedes($1.unicodeScalars.map { $0.value }) }
            .joined(separator: " ")
    }

    func test_textInAGroupThatIsOffIsNotOnThePage() throws {
        XCTAssertEqual(words(try layered("7 0 R")), "extra plain")
    }

    func test_aMembershipDictionaryFollowsItsPolicy() throws {
        XCTAssertEqual(words(try layered("8 0 R")), "inform notes plain")
    }

    func test_withEveryGroupOnAllTheTextCounts() throws {
        XCTAssertEqual(words(try layered("")), "extra inform member notes plain")
    }

    func test_aGroupTurnedBackOnReturnsItsText() throws {
        let document = try layered("7 0 R")
        PdfLayers.setVisible(document, PdfReference(7, 0), true)
        XCTAssertEqual(words(document), "extra inform member notes plain")
    }
}
