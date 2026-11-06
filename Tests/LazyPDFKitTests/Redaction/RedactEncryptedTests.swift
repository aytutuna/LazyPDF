import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactEncryptedTests.cs: the same cases.

final class RedactEncryptedTests: XCTestCase {
    private let id: [UInt8] = (1...16).map { UInt8($0) }

    private func locked(_ strength: PdfCryptStrength) throws -> [UInt8] {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (public ZQXMARKER public) Tj ET")
        let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all, strength: strength, firstId: id)
        return try document.saveRewrite(PdfSaveOptions(security: security, documentId: id))
    }

    private func assertWrongPasswordIsRefused(_ bytes: [UInt8]) {
        XCTAssertThrowsError(try PdfDocument.open(bytes, password: "wrong")) { XCTAssertTrue($0 is PdfReadException) }
    }

    func test_encryptedInputComesOutEncryptedWithTheSamePassword() throws {
        for strength in [PdfCryptStrength.aes256, .aes128] {
            let bytes = try locked(strength)
            assertWrongPasswordIsRefused(bytes)
            let document = try PdfDocument.open(bytes, password: "user")
            let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"))
            XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
            assertWrongPasswordIsRefused(result.bytes)
            let output = try RedactionKit.reopen(result.bytes, "user")
            XCTAssertTrue(output.isEncrypted)
            XCTAssertEqual(RedactionKit.text(output), "public  public")
            XCTAssertFalse(RedactionKit.holds(result.bytes, RedactionKit.marker, "user"))
        }
    }

    func test_encryptionCanBeLeftOff() throws {
        let document = try PdfDocument.open(try locked(.aes256), password: "owner")
        var options = RedactionOptions()
        options.keepEncryption = false
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"), options)
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertFalse(output.isEncrypted)
        XCTAssertFalse(RedactionKit.holds(result.bytes, RedactionKit.marker))
    }

    func test_signedFileIsRedactedAndSaysItsSignaturesAreGone() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET")
        let sig = PdfDictionary()
        sig["Type"] = PdfName("Sig")
        sig["Filter"] = PdfName("Adobe.PPKLite")
        sig["SubFilter"] = PdfName("adbe.pkcs7.detached")
        sig["ByteRange"] = PdfArray([PdfNumber(0), PdfNumber(10), PdfNumber(20), PdfNumber(30)])
        sig["Contents"] = PdfString(bytes: [UInt8](repeating: 0, count: 64), isHex: true)
        let signature = try document.add(sig)
        let fieldDictionary = PdfDictionary()
        fieldDictionary["Type"] = PdfName("Annot")
        fieldDictionary["Subtype"] = PdfName("Widget")
        fieldDictionary["FT"] = PdfName("Sig")
        fieldDictionary["T"] = PdfText.toObject("Signature1")
        fieldDictionary["V"] = signature
        fieldDictionary["Rect"] = PdfArray([PdfNumber(0), PdfNumber(0), PdfNumber(0), PdfNumber(0)])
        fieldDictionary["P"] = document.pages[0].reference
        let field = try document.add(fieldDictionary)
        document.pages[0].dictionary["Annots"] = PdfArray([field])
        let form = PdfDictionary()
        form["Fields"] = PdfArray([field])
        form["SigFlags"] = PdfNumber(3)
        document.catalog["AcroForm"] = form
        XCTAssertTrue(document.isSigned)

        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"))
        let output = try RedactionKit.open(result)
        XCTAssertEqual(result.report.signaturesRemoved, 1)
        XCTAssertTrue(result.report.description.contains("signature is gone"))
        XCTAssertFalse(output.isSigned)
        XCTAssertFalse(Latin1.string(result.bytes).contains("ByteRange"))
        let fields = PdfForm.read(output).fields
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.name, "Signature1")
    }
}
