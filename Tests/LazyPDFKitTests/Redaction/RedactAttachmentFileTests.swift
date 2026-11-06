import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactAttachmentFileTests.cs: the same cases, reading the same files from
// Tests/Fixtures/golden/redaction. Attachments crafted so that a reader other than the check sees the marked word: each ends
// as found or as not checked, never as clean.

final class RedactAttachmentFileTests: XCTestCase {
    private func problems(_ attachment: [UInt8]) throws -> [String] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Names <</EmbeddedFiles <</Names [(original) 6 0 R]>>>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.stream(4, "", "BT /F1 12 Tf 100 100 Td (ZQXMARKER) Tj ET")
        pdf.obj(5, RedactionKit.helvetica)
        pdf.obj(6, "<</Type /Filespec /F (original) /EF <</F 7 0 R>>>>")
        pdf.stream(7, "/Type /EmbeddedFile", attachment)
        let document = try PdfDocument.open(pdf.finish())
        return try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER")).verification.problems
    }

    private func found(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        RedactionKit.assertOneProblem(try problems(try RedactionKit.golden(name)), attached: true, found: true, file: file, line: line)
    }

    private func unread(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        RedactionKit.assertOneProblem(try problems(try RedactionKit.golden(name)), attached: true, found: false, file: file, line: line)
    }

    func test_containerThatIsReadWholeShowsTheWord() throws {
        for name in ["z0-proper.zip", "z6-data-descriptor.zip", "g0-proper.gz", "g4-empty-member-then-secret.gz", "g5-empty-blocks-then-secret.gz", "i1-incremental.pdf"] {
            try found(name)
        }
    }

    func test_containerThatIsNotAccountedForByteForByteIsNotChecked() throws {
        for name in ["z1-unlisted-local.zip", "z2-decoy-directory.zip", "z3-zero-count-offset-past-end.zip", "z3b-zero-count-offset-at-end.zip",
                     "z3c-zero-count-offset-zero.zip", "z4-size-zero.zip", "z4b-size-short.zip", "z5-disk-count-differs.zip", "z7-slack-after-stream.zip",
                     "p1-jpeg-zip.zip", "p2-text-zip.zip", "g2-bad-header-crc.gz", "g3-reserved-flag.gz", "g6-trailing-garbage-1f.gz",
                     "g7-plain-then-1f8b-garbage.gz", "c1-secret.cab", "c2-secret.zlib"] {
            try unread(name)
        }
    }

    func test_zeroPaddingAfterTheLastGzipMemberIsNotAMember() throws {
        XCTAssertEqual(try problems(try RedactionKit.golden("g1-trailing-zeros.gz")), [])
    }

    func test_shortCompressedDataIsNotCheckedWhateverItsSize() throws {
        // 8 bytes of a zlib stream: nothing like the 512 bytes the entropy test wanted.
        RedactionKit.assertOneProblem(try problems([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]), attached: true, found: false)
    }

    func test_textIsSearchedAndFoundOrClean() throws {
        RedactionKit.assertOneProblem(try problems(Latin1.bytes("notes about ZQXMARKER")), attached: true, found: true)
        XCTAssertEqual(try problems(Latin1.bytes("notes about nothing")), [])
    }

    func test_entryThatDoesNotMatchItsChecksumIsNotChecked() throws {
        var packed = try RedactionKit.golden("z0-proper.zip")
        // The CRC-32 of the entry sits in both headers; spoil the one of the directory.
        let directory = try XCTUnwrap(packed.indexOf([0x50, 0x4B, 1, 2]))
        packed[directory + 16] ^= 0xFF
        RedactionKit.assertOneProblem(try problems(packed), attached: true, found: false)
    }
}
