import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/Jbig2GlobalsTests.cs: streams whose /JBIG2Globals point at themselves or at
// each other must not be followed round.
final class Jbig2GlobalsTests: XCTestCase {
    private func open(_ pdf: TestPdf) throws -> PdfDocument { try PdfDocument.open(pdf.finish()) }

    private func data(_ document: PdfDocument, _ number: Int) throws -> [UInt8] {
        try document.data(try XCTUnwrap(document.get(number) as? PdfStream))
    }

    private func damaged(_ document: PdfDocument, _ number: Int) {
        XCTAssertThrowsError(try data(document, number)) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .damaged) }
    }

    func test_aStreamThatNamesItselfAsItsGlobalsIsReadAsItIs() throws {
        let pdf = TestPdf.withPages(1)
        pdf.stream(7, "/DecodeParms <</JBIG2Globals 7 0 R>>", "x")
        XCTAssertEqual(TestPdf.text(try data(try open(pdf), 7)), "x")
    }

    func test_flateStreamWithGlobalsInItsParametersIgnoresThem() throws {
        let pdf = TestPdf.withPages(1)
        pdf.stream(7, "/Filter /FlateDecode /DecodeParms <</JBIG2Globals 8 0 R>>", TestPdf.deflate(TestPdf.latin("abc")))
        pdf.stream(8, "/Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>", "junk")
        XCTAssertEqual(TestPdf.text(try data(try open(pdf), 7)), "abc")
    }

    func test_twoJbig2StreamsThatNameEachOtherAreDamage() throws {
        let pdf = TestPdf.withPages(1)
        pdf.stream(7, "/Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 8 0 R>>", "a")
        pdf.stream(8, "/Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>", "b")
        let document = try open(pdf)
        damaged(document, 7)
        damaged(document, 8)
    }

    func test_aLongChainOfGlobalsIsNotFollowed() throws {
        let pdf = TestPdf.withPages(1)
        for n in 7..<3007 { pdf.stream(n, "/DecodeParms <</JBIG2Globals \(n + 1) 0 R>>", "x") }
        pdf.stream(3007, "", "end")
        XCTAssertEqual(TestPdf.text(try data(try open(pdf), 7)), "x")
    }

    func test_globalsAreDecodedOnceForAllTheImagesThatUseThem() throws {
        let pdf = TestPdf.withPages(1)
        pdf.stream(7, "", try Jbig2Samples.globals())
        let entries = "/Type /XObject /Subtype /Image /Width 64 /Height 40 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>"
        pdf.stream(8, entries, try Jbig2Samples.withGlobals())
        pdf.stream(9, entries, try Jbig2Samples.withGlobals())
        let document = try open(pdf)
        let first = try data(document, 8)
        XCTAssertEqual(first.count, 8 * 40)
        XCTAssertEqual(first, try data(document, 9))
        XCTAssertEqual(first, try Jbig2Samples.withGlobalsPage())
    }

    func test_brokenGlobalsAreAFailureNotEmptyGlobals() throws {
        let pdf = TestPdf.withPages(1)
        pdf.stream(7, "/Filter /FlateDecode", "not flate data at all")
        pdf.stream(8, "/Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 7 0 R>>", try Jbig2Samples.withGlobals())
        damaged(try open(pdf), 8)
    }
}
