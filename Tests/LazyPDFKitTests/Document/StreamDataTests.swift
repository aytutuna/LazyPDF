import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/StreamDataTests.cs: the same cases.

final class StreamDataTests: XCTestCase {
    private func open(_ pdf: TestPdf) throws -> PdfDocument {
        try PdfDocument.open(pdf.finish())
    }

    func test_indirectLengthFilterAndParametersAreResolved() throws {
        // PNG "Up" rows: the second row stores its difference from the first.
        let predicted: [UInt8] = [2, 10, 20, 30, 2, 1, 2, 3]
        let packed = TestPdf.deflate(predicted)
        let pdf = TestPdf.withPages(1)
            .obj(20, "/FlateDecode")
            .obj(21, "<</Predictor 12 /Columns 3>>")
            .obj(22, "[20 0 R]")
            .obj(23, "[21 0 R]")
            .obj(25, String(packed.count))
        pdf.stream(24, "/Filter 22 0 R /DecodeParms 23 0 R", packed)
        pdf.stream(26, "/Filter 20 0 R /DecodeParms 21 0 R", packed, length: -1)
        let document = try open(pdf)
        let expected: [UInt8] = [10, 20, 30, 11, 22, 33]
        XCTAssertEqual(try document.data(try XCTUnwrap(document.get(24) as? PdfStream)), expected)
        XCTAssertEqual(document.rawData(try XCTUnwrap(document.get(24) as? PdfStream)), packed)
        XCTAssertEqual(try document.data(try XCTUnwrap(document.get(26) as? PdfStream)), expected)
    }

    func test_lengthInAnotherObjectIsFollowed() throws {
        let pdf = TestPdf.withPages(1)
        pdf.write("30 0 obj\n<</Length 31 0 R>>\nstream\nhello world\nendstream\nendobj\n31 0 obj\n11\nendobj\n")
        let document = try PdfDocument.open(pdf.finishWithoutXref())
        let stream = try XCTUnwrap(document.resolve(PdfReference(30, 0), as: PdfStream.self))
        XCTAssertEqual(TestPdf.text(document.rawData(stream)), "hello world")
        XCTAssertFalse(document.repairs.contains { $0.contains("/Length") })
    }

    func test_lengthInAMissingObjectFallsBackToEndstream() throws {
        let pdf = TestPdf.withPages(1)
        pdf.write("30 0 obj\n<</Length 99 0 R>>\nstream\nhello world\nendstream\nendobj\n")
        let document = try PdfDocument.open(pdf.finishWithoutXref())
        let stream = try XCTUnwrap(document.resolve(PdfReference(30, 0), as: PdfStream.self))
        XCTAssertEqual(TestPdf.text(document.rawData(stream)), "hello world")
    }

    func test_unsupportedFilterIsAReadException() throws {
        let pdf = TestPdf.withPages(1).stream(9, "/Filter /JBIG2Decode", "x")
        let document = try open(pdf)
        assertReadFails(try document.data(try XCTUnwrap(document.get(9) as? PdfStream)), .unsupported)
    }

    func test_corruptFlateDataIsAReadException() throws {
        let pdf = TestPdf.withPages(1).stream(9, "/Filter /FlateDecode", "this is not zlib data at all")
        let document = try open(pdf)
        assertReadFails(try document.data(try XCTUnwrap(document.get(9) as? PdfStream)), .damaged)
    }

    func test_streamMadeInMemoryGivesItsOwnData() throws {
        let document = try PdfDocument.open(TestPdf.simple(1))
        let stream = PdfStream(PdfDictionary(), data: TestPdf.latin("abc"))
        let reference = try document.add(stream)
        XCTAssertEqual(stream.data, document.rawData(stream))
        XCTAssertEqual(TestPdf.text(try document.data(stream)), "abc")
        XCTAssertEqual(stream.number, reference.number)
        assertSame(stream, document.get(reference.number))
    }

    func test_streamKeywordFollowedByCarriageReturnOnly() throws {
        let pdf = TestPdf.withPages(1)
        pdf.write("30 0 obj\n<</Length 5>>\nstream\rhello\nendstream\nendobj\n")
        let document = try PdfDocument.open(pdf.finishWithoutXref())
        let stream = try XCTUnwrap(document.resolve(PdfReference(30, 0), as: PdfStream.self))
        XCTAssertEqual(TestPdf.text(document.rawData(stream)), "hello")
    }
}
