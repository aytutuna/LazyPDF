import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeDuplicateTests.cs: the same cases. The PdfPig text and page
// count assertions of IdenticalFontsAreMergedAndTextStays and IdenticalPagesStayTwoPages have no twin; the engine's own
// page count and text stand in for them.

final class OptimizeDuplicateTests: XCTestCase {
    private let image = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode"
    private let mask = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode"
    private let pixels = TestPdf.deflate(OptimizeKit.gradient(8, 8, 3))
    private let twoImages = "q 50 0 0 50 0 0 cm /Im0 Do Q q 50 0 0 50 100 0 cm /Im1 Do Q"
    private let twoImageNames = "/XObject <</Im0 5 0 R /Im1 6 0 R>>"

    func test_identicalImagesAreWrittenOnce() throws {
        let file = OptimizeKit.build(twoImages, twoImageNames, { pdf in
            pdf.stream(5, self.image, self.pixels)
            pdf.stream(6, self.image, self.pixels)
        })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.removeDuplicates = true })
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(1, OptimizeKit.count(after) { OptimizeKit.isImage(after, $0) })
        XCTAssertEqual(1, result.steps.first { $0.kind == .removeDuplicates }?.count)
        let xobjects = try XCTUnwrap(after.dict(after.pages[0].resources, "XObject"))
        XCTAssertEqual((xobjects["Im0"] as? PdfReference)?.number, (xobjects["Im1"] as? PdfReference)?.number)
    }

    func test_imagesThatDifferInTheirMaskAreKept() throws {
        let file = OptimizeKit.build(twoImages, twoImageNames, { pdf in
            pdf.stream(5, self.image + " /SMask 7 0 R", self.pixels)
            pdf.stream(6, self.image + " /SMask 8 0 R", self.pixels)
            pdf.stream(7, self.mask, TestPdf.deflate(Array(repeating: 0, count: 64)))
            pdf.stream(8, self.mask, TestPdf.deflate(Array(repeating: 200, count: 64)))
        })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.removeDuplicates = true })
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(4, OptimizeKit.count(after) { OptimizeKit.isImage(after, $0) })
    }

    func test_masksThatAreEqualMergeAndTheImagesFollow() throws {
        let file = OptimizeKit.build(twoImages, twoImageNames, { pdf in
            let equal = TestPdf.deflate(Array(repeating: 0, count: 64))
            pdf.stream(5, self.image + " /SMask 7 0 R", self.pixels)
            pdf.stream(6, self.image + " /SMask 8 0 R", self.pixels)
            pdf.stream(7, self.mask, equal)
            pdf.stream(8, self.mask, equal)
        })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.removeDuplicates = true })
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(2, OptimizeKit.count(after) { OptimizeKit.isImage(after, $0) })
        XCTAssertEqual(2, result.steps.first { $0.kind == .removeDuplicates }?.count)
    }

    func test_identicalFontsAreMergedAndTextStays() throws {
        let font = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"
        let file = OptimizeKit.build("BT /F1 12 Tf 10 100 Td (first) Tj /F2 12 Tf 0 -20 Td (second) Tj ET", "/Font <</F1 5 0 R /F2 6 0 R>>", { pdf in
            pdf.obj(5, font)
            pdf.obj(6, font)
        })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.removeDuplicates = true })
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(1, OptimizeKit.count(after) { ($0 as? PdfDictionary).map { after.name($0, "Type") == "Font" } ?? false })
        XCTAssertEqual(try OptimizeKit.engineText(file), try OptimizeKit.engineText(result.bytes))
        XCTAssertTrue(try OptimizeKit.engineText(result.bytes).contains("second"))
    }

    func test_identicalPagesStayTwoPages() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>")
        pdf.stream(5, "", "0 0 10 10 re f")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfOptimizer(document).run(OptimizeOptions.for(.balanced))
        XCTAssertEqual(2, try PdfDocument.open(result.bytes).pages.count)
    }
}
