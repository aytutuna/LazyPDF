import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeValueTests.cs: the same cases (values and file names that sit above
// or below the node a sanitizer first looks at).

final class SanitizeValueTests: XCTestCase {
    private func run(_ file: [UInt8], _ options: SanitizeOptions = SanitizeOptions()) throws -> SanitizeResult {
        let document = try PdfDocument.open(file)
        return try PdfSanitizer(document).run(options)
    }

    private func page(_ catalogExtra: String, _ annots: String, _ more: [(number: Int, body: String)] = []) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalogExtra)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [\(annots)]>>")
        for (number, body) in more { pdf.obj(number, body) }
        return pdf.finish()
    }

    func test_aValueTheParentPassesDownIsCleared() throws {
        let file = page("/AcroForm <</Fields [4 0 R]>>", "5 0 R", [
            (4, "<</T (p) /FT /Tx /V (MARKERFORM) /Kids [5 0 R]>>"),
            (5, "<</Type /Annot /Subtype /Widget /T (c) /Parent 4 0 R /Rect [10 100 150 120] /P 3 0 R>>"),
        ])
        let result = try run(file)
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERFORM"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .formData))
        let after = try PdfDocument.open(result.bytes)
        XCTAssertTrue((PdfForm.read(after).find("p.c")?.value ?? "").isEmpty)
    }

    func test_aFileUrlInAUrlSpecificationIsAPath() throws {
        let file = page("", "5 0 R", [
            (5, "<</Type /Annot /Subtype /FileAttachment /Rect [0 0 9 9] /FS <</Type /Filespec /FS /URL /F (file:///C:/Users/MARKERNAME/secret/a.pdf)>>>>"),
        ])
        let result = try run(file, SanitizeOptions(embeddedFiles: false))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERNAME"))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "a.pdf"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .filePaths))
    }

    func test_aSubmitAddressWithoutASpecificationIsNotAPath() throws {
        let address = "https://forms.example/app/x/post"
        let file = page("/OpenAction 5 0 R", "", [(5, "<</S /SubmitForm /F (\(address))>>")])
        let result = try run(file, SanitizeOptions(launchActions: false))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, address))
        XCTAssertEqual(0, SanitizeKit.count(result.removed, .filePaths))
    }

    func test_anOpiFileGivenAsASpecificationDictionaryIsCut() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</XObject <</Im0 5 0 R>>>> /Contents 6 0 R>>")
        pdf.stream(5, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 " +
                   "/OPI <</2.0 <</Type /OPI /Version 2.0 /F <</F (/home/MARKERUSER/pic.tif)>>>>>>", "H")
        pdf.stream(6, "", "q 10 0 0 10 0 0 cm /Im0 Do Q")
        let result = try run(pdf.finish())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERUSER"))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "pic.tif"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .filePaths))
    }

    func test_theAppearanceOfASignatureKidBelowAKidIsRemoved() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [8 0 R]>>")
        pdf.obj(4, "<</FT /Sig /T (s) /V 6 0 R /Kids [7 0 R]>>")
        pdf.obj(6, "<</Type /Sig /ByteRange [0 10 20 30] /Contents <3082010a> /Name (MARKERSIGNER)>>")
        pdf.obj(7, "<</T (a) /Parent 4 0 R /Kids [8 0 R]>>")
        pdf.obj(8, "<</Type /Annot /Subtype /Widget /Parent 7 0 R /Rect [10 10 110 50] /P 3 0 R /AP <</N 9 0 R>>>>")
        pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 40]", "BT 0 0 Td (MARKERSIGAP) Tj ET")
        let result = try run(pdf.finish())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERSIGAP"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERSIGNER"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .signatures))
    }
}
