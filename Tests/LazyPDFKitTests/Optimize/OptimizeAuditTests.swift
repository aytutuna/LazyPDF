import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeAuditTests.cs: the same cases.

final class OptimizeAuditTests: XCTestCase {
    private func fixture() throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Metadata 8 0 R /Names <</EmbeddedFiles <</Names [(a.txt) 11 0 R]>>>> /Outlines 13 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [14 0 R] /Resources <</Font <</F1 5 0 R>> /XObject <</Im0 6 0 R>>>>>>")
        pdf.stream(4, "", "BT /F1 12 Tf (text) Tj ET q 50 0 0 50 0 0 cm /Im0 Do Q")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FontDescriptor 7 0 R>>")
        pdf.stream(6, "/Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceGray /BitsPerComponent 8", OptimizeKit.noise(10_000))
        pdf.obj(7, "<</Type /FontDescriptor /FontName /Helvetica /Flags 32>>")
        pdf.stream(8, "/Type /Metadata /Subtype /XML", String(repeating: "m", count: 800))
        pdf.obj(9, "<</Title (T)>>")
        pdf.stream(10, "/Type /EmbeddedFile", String(repeating: "a", count: 3000))
        pdf.obj(11, "<</Type /Filespec /F (a.txt) /EF <</F 10 0 R>>>>")
        pdf.obj(13, "<</Type /Outlines /Count 0>>")
        pdf.obj(14, "<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (note)>>")
        pdf.stream(20, "", String(repeating: "u", count: 5000))
        return try PdfDocument.open(pdf.finish("/Root 1 0 R /Info 9 0 R"))
    }

    func test_everyByteBelongsToOneKind() throws {
        let document = try fixture()
        let audit = PdfOptimizer(document).audit()
        XCTAssertEqual(document.length, audit.fileSize)
        XCTAssertEqual(audit.fileSize, audit.bytes.values.reduce(0, +))
        XCTAssertTrue((10_000...10_400).contains(audit.of(.images)), "\(audit.of(.images))")
        XCTAssertTrue((3000...3300).contains(audit.of(.attachments)), "\(audit.of(.attachments))")
        XCTAssertTrue((800...1000).contains(audit.of(.metadata)), "\(audit.of(.metadata))")
        XCTAssertTrue((5000...5200).contains(audit.of(.unreferenced)), "\(audit.of(.unreferenced))")
        XCTAssertTrue(audit.of(.fonts) > 0)
        XCTAssertTrue(audit.of(.content) > 0)
        XCTAssertTrue(audit.of(.annotations) > 0)
        XCTAssertTrue(audit.of(.structure) > 0)
        XCTAssertTrue(audit.of(.overhead) > 0)
        XCTAssertEqual(0, audit.of(.forms))
        for kind in SpaceKind.allCases {
            XCTAssertFalse(OptimizeText.kindName(kind).isEmpty)
        }
    }

    func test_aRunCountsTheUnreferencedObjects() throws {
        let document = try fixture()
        let result = try PdfOptimizer(document).run(OptimizeKit.off)
        XCTAssertEqual(1, result.steps.first { $0.kind == .removeUnreferenced }?.count)
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, String(repeating: "u", count: 100)))
        XCTAssertTrue(result.sizeAfter < result.sizeBefore - 4000)
    }
}
