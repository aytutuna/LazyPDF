import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/RewriteKeepsTests.cs: the same cases.

final class RewriteKeepsTests: XCTestCase {
    func test_pagesFoundByScanningSurviveARewrite() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /MediaBox [0 0 100 100]>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /MediaBox [0 0 100 100]>>")
        pdf.stream(5, "", "one")
        pdf.stream(6, "", "two")
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertEqual(document.pages.count, 2)

        let reopened = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(reopened.pages.count, 2)
        XCTAssertEqual(TestPdf.text(reopened.pages[1].contents()), "two")
    }

    func test_aDamagedFlateStreamUnderATextFilterKeepsItsOriginalBytes() throws {
        let plain = FilterFixtures.text(400_000)
        var flate = TestPdf.deflate(plain)
        for i in 0..<40 { flate[flate.count * 3 / 4 + i * 7] ^= 0x5A }
        let hex = Latin1.string(PdfFilterEncoders.asciiHex(flate))
        let pdf = TestPdf.withPages(1)
        pdf.stream(9, "/Filter [/ASCIIHexDecode /FlateDecode]", hex)
        pdf.obj(10, "<</Type /Catalog /Pages 2 0 R /Extra 9 0 R>>")
        let document = try PdfDocument.open(pdf.finish("/Root 10 0 R"))
        let stream = try XCTUnwrap(document.get(9) as? PdfStream)
        // The tolerant reader gets something out of it without complaint, which is how the damage hides.
        XCTAssertNotEqual(try document.data(stream).count, plain.count)

        let reopened = try PdfDocument.open(try document.saveRewrite())
        let kept = try XCTUnwrap(reopened.resolve(reopened.catalog["Extra"], as: PdfStream.self))
        XCTAssertEqual(reopened.rawData(kept), Array(hex.utf8))
    }
}
