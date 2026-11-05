import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/ObjectLimitsTests.cs: the same cases, except that
// SharedParameterArraysDoNotMultiplyWhenFlattened does not count allocated bytes (GC.GetAllocatedBytesForCurrentThread
// has no twin); it keeps the decode and a time bound. Three tests at the end are Swift's own: extreme values.

final class ObjectLimitsTests: XCTestCase {
    private func row(_ type: Int, _ second: Int, _ third: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: type), UInt8(truncatingIfNeeded: second >> 16), UInt8(truncatingIfNeeded: second >> 8),
         UInt8(truncatingIfNeeded: second), UInt8(truncatingIfNeeded: third)]
    }

    func test_objectStreamsThatLiveInEachOtherAreCutOff() {
        // Object k is in object stream k + 1, which is in k + 2, and so on: the chain is as long as the file likes.
        let links = 1600
        var rows: [UInt8] = []
        rows += row(0, 0, 255)
        for k in 1..<links { rows += row(2, k + 1, 0) }
        rows += row(0, 0, 0)
        let pdf = TestPdf("%PDF-1.5\n")
        let xref = pdf.position
        rows += row(1, xref, 0)
        pdf.stream(links + 1, "/Type /XRef /Size \(links + 2) /W [1 3 1] /Root 1 0 R", rows)
        let file = pdf.finishWithoutXref() + TestPdf.latin("startxref\n\(xref)\n%%EOF\n")
        assertReadFails(try PdfDocument.open(file))
    }

    func test_sharedParameterArraysDoNotMultiplyWhenFlattened() throws {
        let width = 400
        func refs(_ next: Int) -> String { Array(repeating: "\(next) 0 R", count: width).joined(separator: " ") }
        let pdf = TestPdf.withPages(1)
        pdf.stream(9, "/DecodeParms 10 0 R", "q Q")
        pdf.obj(10, "[\(refs(11))]").obj(11, "[\(refs(12))]").obj(12, "[\(refs(13))]").obj(13, "null")
        let document = try PdfDocument.open(pdf.finish())
        let stream = try XCTUnwrap(document.get(9) as? PdfStream)

        let started = Date()
        XCTAssertEqual(TestPdf.text(try document.data(stream)), "q Q")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func test_streamDataIsReadBeforeTheStreamTakesAnotherNumber() throws {
        let document = try PdfDocument.open(SaveFixtures.make("aes128"))
        let contents = try XCTUnwrap(document.resolve(document.pages[0].dictionary["Contents"], as: PdfStream.self))
        let number = try document.add(PdfDictionary()).number + 40
        document.set(number, contents)
        XCTAssertEqual(TestPdf.text(document.rawData(contents)), SaveFixtures.pageOne)
        let reopened = try PdfDocument.open(document.saveIncremental())
        XCTAssertEqual(TestPdf.text(try reopened.data(try XCTUnwrap(reopened.get(number) as? PdfStream))), SaveFixtures.pageOne)
    }

    func test_decodedSizeCanBeCappedPerCall() throws {
        let pdf = TestPdf.withPages(1)
        pdf.stream(9, "/Filter /FlateDecode", TestPdf.deflate([UInt8](repeating: 0, count: 100_000)))
        let document = try PdfDocument.open(pdf.finish())
        let stream = try XCTUnwrap(document.get(9) as? PdfStream)
        XCTAssertEqual(try document.data(stream).count, 100_000)
        assertReadFails(try document.data(stream, 1000))
    }

    func test_xrefStreamIndexThatWrapsALongIsDamaged() throws {
        let pdf = TestPdf.withPages(1)
        let file = pdf.finishWithoutXref()
        let xref = pdf.position
        var rows: [UInt8] = []
        rows += row(0, 0, 255)
        for n in 1...4 { rows += row(1, try XCTUnwrap(file.indexOf(TestPdf.latin("\(n) 0 obj"))), 0) }
        rows += row(1, xref, 0)
        rows += row(1, 20, 0)
        pdf.stream(5, "/Type /XRef /Size 6 /W [1 3 1] /Index [0 6 9223372036854775807 1] /Root 1 0 R", rows)
        let document = try PdfDocument.open(pdf.finishWithoutXref() + TestPdf.latin("startxref\n\(xref)\n%%EOF\n"))
        XCTAssertTrue(document.xrefRebuilt)
        XCTAssertTrue(document.objectNumbers.allSatisfy { $0 > 0 })
    }

    // The extreme values below are not in the C# tests: Swift traps where C# wraps or throws, so each place a number
    // from the file becomes a position, a length or a count gets Int.max, Int.min, -1 and a value past Int.
    private static let extremes = ["9223372036854775807", "9223372036854775808", "18446744073709551615", "-1", "-9223372036854775808", "0"]

    /// Opens the file and touches what a caller would; a read that fails must fail as `PdfReadException`.
    private func assertOpensOrFailsCleanly(_ file: [UInt8], _ what: String) {
        do {
            let document = try PdfDocument.open(file)
            _ = document.pages.count
            for number in document.objectNumbers {
                if let stream = document.get(number) as? PdfStream { _ = try? document.data(stream) }
            }
        } catch is PdfReadException {
        } catch {
            XCTFail("\(what): \(error)")
        }
    }

    func test_extremePositionsInTheTrailerAndStartxrefAreNotFatal() {
        for value in Self.extremes {
            assertOpensOrFailsCleanly(TestPdf.withPages(1).finish(startxref: value), "startxref \(value)")
            assertOpensOrFailsCleanly(TestPdf.withPages(1).finish("/Root 1 0 R /Prev \(value)"), "/Prev \(value)")
            assertOpensOrFailsCleanly(TestPdf.withPages(1).finish("/Root 1 0 R /XRefStm \(value)"), "/XRefStm \(value)")
            assertOpensOrFailsCleanly(TestPdf.withPages(1).finish("/Root 1 0 R /Size \(value)"), "/Size \(value)")
        }
    }

    func test_extremeLengthsAndCountsInStreamsAreNotFatal() {
        for value in Self.extremes {
            let length = TestPdf.withPages(1)
            length.stream(9, "/Length \(value)", "abc", length: -1)
            assertOpensOrFailsCleanly(length.finish(), "/Length \(value)")

            let objects = TestPdf("%PDF-1.5\n")
            objects.stream(5, "/Type /ObjStm /N \(value) /First \(value)", "1 0 <</Type /Catalog>>")
            objects.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>").obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 9 9]>>")
            assertOpensOrFailsCleanly(objects.finishWithoutXref(), "/N and /First \(value)")

            let first = TestPdf("%PDF-1.5\n")
            first.stream(5, "/Type /ObjStm /N 1 /First \(value)", "1 \(value) <</Type /Catalog>>")
            assertOpensOrFailsCleanly(first.finishWithoutXref(), "offset \(value)")
        }
    }

    func test_crossReferenceStreamFieldsWithTheHighBitSetAreNotFatal() {
        for widths in [[1, 8, 1], [8, 8, 8], [1, 4, 4], [2, 8, 2], [0, 8, 0], [1, 9, 1]] {
            let length = widths.reduce(0, +)
            var full = [UInt8](repeating: 0xFF, count: length)
            if widths[0] == 1 { full[0] = 1 }
            let pdf = TestPdf.withPages(1)
            let xref = pdf.position
            pdf.stream(5, "/Type /XRef /Size 3 /W [\(widths.map(String.init).joined(separator: " "))] /Index [0 3] /Root 1 0 R",
                       [UInt8](repeating: 0, count: length) + full + full)
            let file = pdf.finishWithoutXref() + TestPdf.latin("startxref\n\(xref)\n%%EOF\n")
            assertOpensOrFailsCleanly(file, "/W \(widths)")
        }
    }
}
