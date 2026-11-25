import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeSignatureTests.cs: the same cases. The PdfPig page count of the
// first test has no twin; the engine's own stands in for it.

final class SanitizeSignatureTests: XCTestCase {
    private func signed() -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R] /SigFlags 3>> /Perms <</DocMDP 5 0 R>> /DSS <</OCSPs [7 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Annots [4 0 R]>>")
        pdf.obj(4, "<</Type /Annot /Subtype /Widget /FT /Sig /T (Sign1) /V 5 0 R /Rect [10 10 110 50] /P 3 0 R /AP <</N 8 0 R>>>>")
        pdf.obj(5, "<</Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 10 20 30] /Contents <3082010a3082010a> " +
            "/Name (MARKERSIGNER) /Reason (MARKERREASON) /Location (MARKERPLACE) /M (D:20240101000000Z)>>")
        pdf.stream(6, "", "0 g 10 10 20 20 re f")
        pdf.stream(7, "", "MARKEROCSP")
        pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 100 40]", "BT 0 0 Td (MARKERSIGAP) Tj ET")
        return pdf.finish()
    }

    private let markers = ["MARKERSIGNER", "MARKERREASON", "MARKERPLACE", "MARKEROCSP", "MARKERSIGAP", "ByteRange", "DocMDP", "SigFlags"]

    func test_theSanitizerLeavesNoSignatureDictionaryDssPermsOrAppearance() throws {
        let file = signed()
        for marker in markers { XCTAssertTrue(try OptimizeKit.everywhere(file, marker), marker) }
        let document = try PdfDocument.open(file)
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        for marker in markers { XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, marker), marker) }
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .signatures))
        let after = try PdfDocument.open(result.bytes)
        XCTAssertFalse(after.isSigned)
        XCTAssertEqual(1, after.pages.count)
    }

    func test_scanListsTheSignature() throws {
        let document = try PdfDocument.open(signed())
        XCTAssertEqual(1, SanitizeKit.count(try PdfSanitizer(document).scan(), .signatures))
    }

    func test_theOptimizerKeepsTheLookOfASignedField() throws {
        let document = try PdfDocument.open(signed())
        let result = try PdfOptimizer(document).run(OptimizeOptions())
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "MARKERSIGAP"))
    }

    func test_aFieldTypeMarksTheSignatureWhenTheValueHasNeitherTypeNorByteRange() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [5 0 R]>>")
        pdf.obj(4, "<</FT /Sig /T (sig) /Kids [5 0 R] /V 6 0 R>>")
        pdf.obj(5, "<</Type /Annot /Subtype /Widget /Parent 4 0 R /Rect [0 0 0 0] /P 3 0 R>>")
        pdf.obj(6, "<</Filter /Adobe.PPKLite /SubFilter /adbe.x509.rsa_sha1 /Cert (x) /Contents <3082> /Name (MARKERSIGNER)>>")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERSIGNER"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .signatures))
    }

    func test_aDocumentTimeStampWithoutAFieldGoesToo() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [4 0 R]>>")
        pdf.obj(4, "<</Type /Annot /Subtype /Widget /FT /Sig /T (ts) /V 5 0 R /Rect [0 0 0 0] /P 3 0 R>>")
        pdf.obj(5, "<</Type /DocTimeStamp /Filter /Adobe.PPKLite /SubFilter /ETSI.RFC3161 /ByteRange [0 1 2 3] /Contents <30820101> /Name (MARKERSIGNER)>>")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERSIGNER"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .signatures))
    }
}
