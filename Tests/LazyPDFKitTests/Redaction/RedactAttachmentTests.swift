import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactAttachmentTests.cs: the same cases. The original attached to the file in
// a container the byte search cannot see into.

final class RedactAttachmentTests: XCTestCase {
    private let word = "ZQXMARKER"

    private func zip() throws -> [UInt8] {
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

    private func redactWith(_ attachment: [UInt8]) throws -> RedactionResult {
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
