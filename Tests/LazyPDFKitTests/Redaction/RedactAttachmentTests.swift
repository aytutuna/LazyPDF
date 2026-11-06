import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactAttachmentTests.cs: the same cases. The original attached to the file in
// a container the byte search cannot see into.

final class RedactAttachmentTests: XCTestCase {
    let word = "ZQXMARKER"

    func zip() throws -> [UInt8] {
        var text = ""
        for i in 0..<50 { text += "\(word) is the secret number \(i)\n" }
        return try ExportZip.make([ExportZipEntry("original.txt", Latin1.bytes(text))])
    }

    private func compressedPdf() -> [UInt8] {
        let inner = TestPdf()
        inner.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        inner.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        inner.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        inner.stream(4, "/Filter /FlateDecode", TestPdf.deflate(TestPdf.latin("BT /F1 12 Tf 100 100 Td (\(word)) Tj ET")))
        inner.obj(5, RedactionKit.helvetica)
        return inner.finish()
    }

    func redactWith(_ attachment: [UInt8]) throws -> RedactionResult {
        XCTAssertFalse(Latin1.string(attachment).contains(word))
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Names <</EmbeddedFiles <</Names [(original) 6 0 R]>>>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.stream(4, "", "BT /F1 12 Tf 100 100 Td (\(word)) Tj ET")
        pdf.obj(5, RedactionKit.helvetica)
        pdf.obj(6, "<</Type /Filespec /F (original) /EF <</F 7 0 R>>>>")
        pdf.stream(7, "/Type /EmbeddedFile", attachment)
        let document = try PdfDocument.open(pdf.finish())
        return try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, word))
    }

    func test_zipHoldingTheWordIsReported() throws {
        RedactionKit.assertOneProblem(try redactWith(zip()).verification.problems, attached: true, found: true)
    }

    func test_pdfWithCompressedStreamsHoldingTheWordIsReported() throws {
        RedactionKit.assertOneProblem(try redactWith(compressedPdf()).verification.problems, attached: true, found: true)
    }

    func test_containerThatCannotBeOpenedIsNotCalledClean() throws {
        var broken = try zip()
        for i in 40..<(broken.count - 40) { broken[i] = 7 }
        let problems = try redactWith(broken).verification.problems
        RedactionKit.assertOneProblem(problems, attached: true, found: false)
    }

    func test_attachmentWithoutTheWordIsLeftAlone() throws {
        let result = try redactWith(Latin1.bytes("nothing to see here"))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }
}

extension RedactAttachmentTests {
    // No C# twin: the C# reads these containers with ZipArchive, which refuses a directory that does not hold the number of
    // entries the end record says. The end record of ExportZip's output: entries on this disk at 8, in all at 10.
    private func endRecord(_ zip: [UInt8]) -> Int { zip.lastIndexOf([0x50, 0x4B, 5, 6]) ?? 0 }

    func test_zipWithTheEntryCountZeroedIsNotCalledClean() throws {
        var packed = try zip()
        let end = endRecord(packed)
        for i in 8..<12 { packed[end + i] = 0 }
        XCTAssertThrowsError(try RedactionArchive.entries(packed))
        RedactionKit.assertOneProblem(try redactWith(packed).verification.problems, attached: true, found: false)
    }

    func test_zipWithMoreEntriesThanItsEndRecordSaysIsNotCalledClean() throws {
        var packed = try ExportZip.make([ExportZipEntry("a.txt", Latin1.bytes("first")), ExportZipEntry("b.txt", Latin1.bytes(String(repeating: "\(word) ", count: 20)))])
        let end = endRecord(packed)
        packed[end + 8] = 1
        packed[end + 10] = 1
        XCTAssertThrowsError(try RedactionArchive.entries(packed))
        RedactionKit.assertOneProblem(try redactWith(packed).verification.problems, attached: true, found: false)
    }

    func test_zipEntriesAreReadStoredOrDeflated() throws {
        let text = Latin1.bytes(String(repeating: "\(word) is the secret number\n", count: 50))
        let packed = try ExportZip.make([ExportZipEntry("big.txt", text), ExportZipEntry("tiny.txt", Latin1.bytes("ab"))])
        let entries = try RedactionArchive.entries(packed)
        XCTAssertEqual(entries.map { $0.method }, [8, 0])
        XCTAssertEqual(try RedactionArchive.inflate(entries[0], 1 << 20).bytes, text)
        XCTAssertEqual(try RedactionArchive.inflate(entries[1], 1 << 20).bytes, Latin1.bytes("ab"))
        XCTAssertTrue(try RedactionArchive.inflate(entries[0], 100).over)
    }

    func test_gzipMembersAreAllReadAndJoined() throws {
        let packed = RedactionKit.gzip(Latin1.bytes("hello ")) + RedactionKit.gzip(Latin1.bytes("world \(word)"))
        XCTAssertEqual(try RedactionArchive.gunzip(packed, 1 << 20).bytes, Latin1.bytes("hello world \(word)"))
        XCTAssertEqual(try RedactionArchive.gunzip(RedactionKit.gzip(Latin1.bytes("one")), 1 << 20).bytes, Latin1.bytes("one"))
    }

    func test_gzipWithASecondMemberHoldingTheWordIsReported() throws {
        let packed = RedactionKit.gzip(Latin1.bytes("hello world")) + RedactionKit.gzip(Latin1.bytes("\(word) is here"))
        RedactionKit.assertOneProblem(try redactWith(packed).verification.problems, attached: true, found: true)
    }

    func test_gzipWithBytesThatAreNoMemberIsNotCalledClean() throws {
        let one = RedactionKit.gzip(Latin1.bytes("hello world"))
        XCTAssertThrowsError(try RedactionArchive.gunzip(one + [1, 2, 3], 1 << 20))
        // A trailer that is another member's, as a forged checksum would give.
        var forged = one + RedactionKit.gzip(Latin1.bytes("\(word) pad pad"))
        for i in 0..<8 { forged[forged.count - 8 + i] = one[one.count - 8 + i] }
        XCTAssertThrowsError(try RedactionArchive.gunzip(forged, 1 << 20))
        RedactionKit.assertOneProblem(try redactWith(forged).verification.problems, attached: true, found: false)
    }
}
