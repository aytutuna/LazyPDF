import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/EncryptionTests.cs: the same cases.

final class EncryptionTests: XCTestCase {
    private static let fileId: [UInt8] = (1...16).map { UInt8($0) }

    /// Objects 1 to 4 plain pages, an /Info in 5, the content in 6, an object stream in 7 and the /Encrypt dictionary in 8.
    private func encryptedFile(_ strength: PdfCryptStrength, _ user: String) -> (file: [UInt8], security: PdfSecurity) {
        let security = PdfSecurity.create(userPassword: user, ownerPassword: "owner", permissions: .all, strength: strength,
                                          firstId: Self.fileId, random: SeededRandom(7))
        func hex(_ number: Int, _ text: String) -> String {
            "<" + Hex.string(security.encryptString(number, 0, Latin1.bytes(text))) + ">"
        }
        let pdf = TestPdf("%PDF-1.6\n")
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Lang " + hex(1, "en-US") + ">>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /MediaBox [0 0 50 50]>>")
        pdf.obj(5, "<</Title " + hex(5, "Secret title") + ">>")
        pdf.stream(6, "", security.encryptStream(6, 0, TestPdf.latin("0 0 m"), PdfDictionary()))
        // Strings inside an object stream are not encrypted themselves; the stream is.
        let packed = "9 0 <</Note (plain text)>>"
        pdf.stream(7, "/Type /ObjStm /N 1 /First 4", security.encryptStream(7, 0, TestPdf.latin(packed), PdfDictionary()))
        pdf.obj(8, security.dictionary.description)
        let id = Hex.string(Self.fileId)
        return (pdf.finish("/Root 1 0 R /Info 5 0 R /Encrypt 8 0 R /ID [<\(id)> <\(id)>]"), security)
    }

    func test_stringsAndStreamsAreDecryptedAsObjectsLoad() throws {
        for strength in [PdfCryptStrength.aes128, .aes256] {
            let (file, _) = encryptedFile(strength, "")
            let document = try PdfDocument.open(file)
            XCTAssertTrue(document.isEncrypted, "\(strength)")
            XCTAssertNotNil(document.security, "\(strength)")
            XCTAssertEqual(TestPdf.text(try XCTUnwrap(document.info?["Title"] as? PdfString).bytes), "Secret title", "\(strength)")
            XCTAssertEqual(TestPdf.text(try XCTUnwrap(document.catalog["Lang"] as? PdfString).bytes), "en-US", "\(strength)")
            XCTAssertEqual(TestPdf.text(document.pages[0].contents()), "0 0 m", "\(strength)")
        }
    }

    func test_encryptDictionaryIsNotDecrypted() throws {
        let (file, security) = encryptedFile(.aes256, "")
        let document = try PdfDocument.open(file)
        let stored = try XCTUnwrap(document.get(8) as? PdfDictionary)
        XCTAssertEqual(try XCTUnwrap(security.dictionary["U"] as? PdfString).bytes, try XCTUnwrap(stored["U"] as? PdfString).bytes)
    }

    func test_passwordIsAskedFor() throws {
        let (file, _) = encryptedFile(.aes256, "open sesame")
        assertReadFails(try PdfDocument.open(file), .passwordRequired)
        assertReadFails(try PdfDocument.open(file, password: "wrong"), .passwordRequired)
        let document = try PdfDocument.open(file, password: "open sesame")
        XCTAssertEqual(TestPdf.text(try XCTUnwrap(document.info?["Title"] as? PdfString).bytes), "Secret title")
    }

    func test_encryptedFileWithABrokenTableIsRebuiltAndStillDecrypts() throws {
        let (file, _) = encryptedFile(.aes128, "")
        let document = try PdfDocument.open(TestPdf.replace(file, "startxref", "startxxxxx"))
        XCTAssertTrue(document.xrefRebuilt)
        XCTAssertEqual(TestPdf.text(try XCTUnwrap(document.info?["Title"] as? PdfString).bytes), "Secret title")
        XCTAssertEqual(TestPdf.text(document.pages[0].contents()), "0 0 m")
        let note = try XCTUnwrap(document.get(9) as? PdfDictionary)
        XCTAssertEqual(TestPdf.text(try XCTUnwrap(note["Note"] as? PdfString).bytes), "plain text")
    }
}
