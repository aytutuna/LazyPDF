import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactOpaqueFileTests.cs: the same cases. The check reports what it could not
// look into, and looks into what a viewer of the attachment would read.

final class RedactOpaqueFileTests: XCTestCase {
    private func redactWithAttachment(_ attachment: [UInt8], _ catalogExtra: String = "/Names <</EmbeddedFiles <</Names [(a.bin) 8 0 R]>>>>") throws -> RedactionResult {
        let document = try RedactionFiles.open(RedactionFiles.word, "", { pdf in
            pdf.obj(8, "<</Type /Filespec /F (a.bin) /EF <</F 9 0 R>>>>")
            pdf.stream(9, "/Type /EmbeddedFile", attachment)
        }, catalogExtra: catalogExtra)
        return try PdfRedactor(document).apply([RedactionMark.fromRect(0, RedactionFiles.over)])
    }

    func test_picturesInAnImageCodecAreNotAnUnreadStream() throws {
        let document = try RedactionFiles.open(RedactionFiles.word + " q 20 0 0 20 400 600 cm /Im1 Do Q", "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0xFF, 0xD9])
        }
        let result = try RedactionFiles.apply(document, RedactionMark.fromRect(0, RedactionFiles.over))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }

    func test_attachedSourceThatIsCodedByItsFontIsRead() throws {
        let nested = TestPdf()
        nested.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        nested.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        nested.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        nested.stream(4, "", "BT /F1 12 Tf 100 100 Td <0102030405060708> Tj ET")
        nested.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /Differences [1 /Z /Q /X /C /Y /C /L /E]>>>>")
        let attached = nested.finish()
        let document = try RedactionFiles.open("BT /F1 12 Tf 100 100 Td (ZQXCYCLE) Tj ET", "", { pdf in
            pdf.obj(8, "<</Type /Filespec /F (a.pdf) /EF <</F 9 0 R>>>>")
            pdf.stream(9, "/Type /EmbeddedFile", attached)
        }, catalogExtra: "/Names <</EmbeddedFiles <</Names [(a.pdf) 8 0 R]>>>>")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, RedactionFiles.over)])
        XCTAssertFalse(result.verification.isClean)
    }

    func test_attachmentInAFormatThatIsNotOpenedIsNotChecked() throws {
        let result = try redactWithAttachment([0x28, 0xB5, 0x2F, 0xFD, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertFalse(result.verification.isClean)
    }

    func test_attachmentThatLooksCompressedIsNotChecked() throws {
        var random = SeededRandom(7)
        let bytes = (0..<4096).map { _ in UInt8.random(in: 0...255, using: &random) }
        XCTAssertFalse(try redactWithAttachment(bytes).verification.isClean)
    }

    func test_plainTextAttachmentIsChecked() throws {
        XCTAssertTrue(try redactWithAttachment(Latin1.bytes("hello there")).verification.isClean)
    }

    func test_gzipUnderAPrivateKeyIsOpened() throws {
        let data = Latin1.bytes("ZQXSECRET ZQXSECRET")
        // A gzip member is the deflate stream of a zlib one between its own header and trailer.
        let zlib = Deflate.zlib(data, .optimal)
        let crc = ExportZip.crc32(data)
        var packed: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]
        packed += zlib[2..<(zlib.count - 4)]
        packed += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        packed += [UInt8(data.count), 0, 0, 0]
        let document = try RedactionFiles.open(RedactionFiles.word, "", { pdf in pdf.stream(9, "", packed) }, catalogExtra: "/Backup 9 0 R")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, RedactionFiles.over)])
        XCTAssertFalse(result.verification.isClean)
    }
}
