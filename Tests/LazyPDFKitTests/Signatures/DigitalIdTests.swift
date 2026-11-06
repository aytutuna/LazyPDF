#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/DigitalIdTests.cs: the same cases. The wrong-password case expects any
// thrown error, as the C# expects any CryptographicException. The PFX file is written with SecItemExport, which only
// macOS has, so the round trip runs there alone; iOS is checked for the refusal.

final class DigitalIdTests: XCTestCase {
    private let start = DateTimeOffset(2026, 3, 1, 0, 0, 0)

    private func keySize(_ certificate: X509Certificate) throws -> Int {
        var outer = AsnReader(certificate.encodedKeyValue)
        var sequence = try outer.readSequence()
        let modulus = try sequence.readInteger().magnitude
        let top = modulus.first ?? 0
        return (modulus.count - 1) * 8 + (8 - top.leadingZeroBitCount)
    }

    func test_aDigitalIdIsASelfSignedCertificateForSigningWithItsKey() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", "ada@example.org", start, years: 5, keyBits: 2048)

        XCTAssertNotNil(id.privateKey)
        XCTAssertEqual(id.simpleName, "Ada Lovelace")
        XCTAssertEqual(X509Certificate.attributes(id.subjectName)?.first { $0.oid == "1.2.840.113549.1.9.1" }?.value, "ada@example.org")
        XCTAssertEqual(id.subjectName, id.issuerName)
        XCTAssertEqual(id.notBefore, start)
        XCTAssertEqual(id.notAfter, start.adding(years: 5))
        XCTAssertEqual(try keySize(id), 2048)
        let usage: KeyUsage = [.digitalSignature, .nonRepudiation]
        XCTAssertEqual(try id.keyUsage(), usage)
        XCTAssertEqual(try id.basicConstraints()?.certificateAuthority, false)
    }

    func test_thePfxCarriesTheKeyAndLoadsAgain() throws {
        #if os(macOS)
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)

        let pfx = try PdfDigitalId.exportPfx(id, "pass word")
        let loaded = try PdfDigitalId.importPfx(pfx, "pass word")

        XCTAssertEqual(id.thumbprint, loaded.thumbprint)
        XCTAssertNotNil(loaded.privateKey)
        XCTAssertThrowsError(try PdfDigitalId.importPfx(pfx, "wrong"))
        #else
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)
        XCTAssertThrowsError(try PdfDigitalId.exportPfx(id, "pass word")) { XCTAssertTrue($0 is PdfReadException) }
        #endif
    }

    func test_namesWithCommasQuotesAndTurkishLettersSurvive() throws {
        let name = "Doğan, \"Şık\" Ü."
        let id = try PdfDigitalId.create(name, nil, start, keyBits: 2048)

        XCTAssertEqual(id.simpleName, name)
    }

    func test_aSignatureWithItIsValidButNotTrustedUntilTheCallerTrustsIt() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", nil, start, keyBits: 2048)
        let signed = try PdfSigner.sign(SignatureKit.plain(), PdfSignRequest(id, try XCTUnwrap(start.adding(days: 3))))

        let reports = try PdfSignatureVerifier.verify(signed)
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertEqual(report.sentence, "Signed by Ada Lovelace on 4 Mar 2026. The signer is not trusted.")

        var options = VerifyOptions()
        options.trustAnchors = [id]
        let trusted = try PdfSignatureVerifier.verify(signed, options)
        XCTAssertEqual(trusted.count, 1)
        XCTAssertEqual(trusted.first?.verdict, .valid)
    }
}
#endif
