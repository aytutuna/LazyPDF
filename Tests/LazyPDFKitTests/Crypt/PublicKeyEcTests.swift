#if canImport(Security)
import XCTest
import Security
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/PublicKeyEcTests.cs on the handler instead of a saved document. The
// golden envelopes are the C#'s: CmsAgreementTests.swift checks them byte for byte without the system; here the
// system's key agreement opens them.

final class PublicKeyEcTests: XCTestCase {
    private let p256 = PublicKeyFiles.ecCertificate("Curve256")
    private let p384 = PublicKeyFiles.ecCertificate("Curve384", bits: 384)

    func test_eachKindOfRecipientOpensTheSameFileWithTheirOwnPermissions() throws {
        let created = try PdfSecurity.createPublicKey([
            PdfRecipient(PublicKeyFiles.alice, permissions: .print),
            PdfRecipient(p256, permissions: .all, canChangeEncryption: true),
            PdfRecipient(p384, permissions: .copy),
        ], .aes256)
        let plain = Array("one string for all".utf8)
        let stored = created.encryptString(5, 0, plain)

        let rsa = try XCTUnwrap(PdfSecurity.openPublicKey(created.dictionary, PublicKeyFiles.alice))
        let first = try XCTUnwrap(PdfSecurity.openPublicKey(created.dictionary, p256))
        let second = try XCTUnwrap(PdfSecurity.openPublicKey(created.dictionary, p384))

        XCTAssertEqual(rsa.permissions, .print)
        XCTAssertEqual(first.permissions, .all)
        XCTAssertTrue(first.openedAsOwner)
        XCTAssertEqual(second.permissions, .copy)
        XCTAssertFalse(second.openedAsOwner)
        for reader in [rsa, first, second] { XCTAssertEqual(reader.decryptString(5, 0, stored), plain) }
    }

    func test_aesOneTwentyEightCurveRecipient() throws {
        let created = try PdfSecurity.createPublicKey([PdfRecipient(p256)], .aes128)

        let reader = try XCTUnwrap(PdfSecurity.openPublicKey(created.dictionary, p256))

        XCTAssertEqual(reader.revision, 4)
        XCTAssertTrue(reader.isPublicKey)
    }

    func test_otherCertificatesAreNotRecipients() throws {
        let created = try PdfSecurity.createPublicKey([PdfRecipient(p256)], .aes256)

        XCTAssertNil(try PdfSecurity.openPublicKey(created.dictionary, PublicKeyFiles.ecCertificate("Other")))
        XCTAssertNil(try PdfSecurity.openPublicKey(created.dictionary, p384))
        XCTAssertNil(try PdfSecurity.openPublicKey(created.dictionary, PublicKeyFiles.alice))
        XCTAssertNil(try PdfSecurity.openPublicKey(created.dictionary, PublicKeyFiles.publicPart(p256)))
    }

    func test_canProtectNeedsAKnownCurveAndKeyAgreement() throws {
        let signOnly = PublicKeyFiles.ecCertificate("Signer", usage: [0x03, 0x02, 0x07, 0x80])

        XCTAssertTrue(PdfRecipient.canProtect(p256))
        XCTAssertTrue(PdfRecipient.canProtect(p384))
        XCTAssertFalse(PdfRecipient.canProtect(signOnly))
        XCTAssertFalse(PdfRecipient.canProtect(PublicKeyFiles.ecCertificate("Big", bits: 521)))
        XCTAssertThrowsError(try PdfSecurity.createPublicKey([PdfRecipient(signOnly)], .aes256))
    }

    func test_goldenEnvelopesWrittenByTheCSharpOpen() throws {
        for golden in [EcGolden.p256, EcGolden.p384] {
            let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(Hex.bytes(golden.certificate)) as CFData))
            let point = try XCTUnwrap(SecCertificateCopyKey(certificate).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? })
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
            let key = try XCTUnwrap(SecKeyCreateWithData(point + Data(Hex.bytes(golden.recipientKey)) as CFData, attributes as CFDictionary, nil))

            let filter = PdfDictionary()
            filter.add("Type", PdfName("CryptFilter"))
            filter.add("CFM", PdfName("AESV3"))
            filter.add("AuthEvent", PdfName("DocOpen"))
            filter.add("Length", PdfNumber(32))
            filter.add("Recipients", PdfArray([PdfString(bytes: Hex.bytes(golden.envelope), isHex: true)]))
            let cf = PdfDictionary()
            cf.add("DefaultCryptFilter", filter)
            let dictionary = PdfDictionary()
            dictionary.add("Filter", PdfName("Adobe.PubSec"))
            dictionary.add("SubFilter", PdfName("adbe.pkcs7.s5"))
            dictionary.add("V", PdfNumber(5))
            dictionary.add("Length", PdfNumber(256))
            dictionary.add("CF", cf)
            dictionary.add("StmF", PdfName("DefaultCryptFilter"))
            dictionary.add("StrF", PdfName("DefaultCryptFilter"))

            let reader = try PdfSecurity.openPublicKey(dictionary, PdfCertificate(certificate: certificate, privateKey: key))

            XCTAssertNotNil(reader, golden.curve)
        }
    }
}
#endif
