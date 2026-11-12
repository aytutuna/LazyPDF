#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/PublicKeyRoundTripTests.cs: DictionaryHasTheShapeOfTheSpec, NewHandlerIsAnOwner
// and ReaderDecryptsWhatTheCreatorEncrypted as they are; EachRecipientOpensTheSameFileWithTheirOwnPermissions and
// DefaultRecipientHasAllPermissionsButNoOwnership on the handler instead of a saved document. Left out, because
// they save and open a PdfDocument: RecipientReadsWhatWasSealed, FileRecordsTheHandlerInItsHeaderAndTrailer,
// TwoSealsOfTheSameFileDiffer, PathOverloadOpensTheFile, IncrementalUpdateOfSealedFileOpensAgain.
// RecipientCountIsBounded is a precondition in Swift, which a test cannot catch.

final class PublicKeyRoundTripTests: XCTestCase {
    func test_dictionaryHasTheShapeOfTheSpec() throws {
        for (strength, subFilter, v, method) in [(PdfCryptStrength.aes256, "adbe.pkcs7.s5", 5, "AESV3"),
                                                 (PdfCryptStrength.aes128, "adbe.pkcs7.s5", 4, "AESV2")] {
            let dictionary = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], strength).dictionary

            XCTAssertEqual((dictionary["Filter"] as? PdfName)?.value, "Adobe.PubSec")
            XCTAssertEqual((dictionary["SubFilter"] as? PdfName)?.value, subFilter)
            XCTAssertEqual((dictionary["V"] as? PdfNumber)?.value, Double(v))
            let cf = try XCTUnwrap(dictionary["CF"] as? PdfDictionary)
            let filter = try XCTUnwrap(cf[try XCTUnwrap((dictionary["StmF"] as? PdfName)?.value)] as? PdfDictionary)
            XCTAssertEqual((filter["CFM"] as? PdfName)?.value, method)
            let recipients = try XCTUnwrap(filter["Recipients"] as? PdfArray)
            XCTAssertEqual(recipients.items.count, 1)
            XCTAssertEqual((recipients.items.first as? PdfString)?.bytes.first, 0x30)
        }
    }

    func test_eachRecipientOpensTheSameFileWithTheirOwnPermissions() throws {
        let created = try PdfSecurity.createPublicKey([
            PdfRecipient(PublicKeyFiles.alice, permissions: [.print, .copy]),
            PdfRecipient(PublicKeyFiles.bob, permissions: .all, canChangeEncryption: true),
        ], .aes256)
        let plain = Array("one string for both".utf8)
        let stored = created.encryptString(5, 0, plain)

        let alice = try XCTUnwrap(PdfSecurity.openPublicKey(created.dictionary, PublicKeyFiles.alice))
        let bob = try XCTUnwrap(PdfSecurity.openPublicKey(created.dictionary, PublicKeyFiles.bob))

        XCTAssertEqual(alice.permissions, [.print, .copy])
        XCTAssertFalse(alice.openedAsOwner)
        XCTAssertEqual(bob.permissions, .all)
        XCTAssertTrue(bob.openedAsOwner)
        XCTAssertEqual(alice.decryptString(5, 0, stored), plain)
        XCTAssertEqual(bob.decryptString(5, 0, stored), plain)
    }

    func test_defaultRecipientHasAllPermissionsButNoOwnership() throws {
        let created = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], .aes256)

        let reader = try XCTUnwrap(PdfSecurity.openPublicKey(created.dictionary, PublicKeyFiles.alice))

        XCTAssertEqual(reader.permissions, .all)
        XCTAssertFalse(reader.openedAsOwner)
        XCTAssertTrue(reader.isPublicKey)
        XCTAssertEqual(reader.revision, 6)
    }

    func test_newHandlerIsAnOwner() throws {
        let created = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice, permissions: .print)], .aes256)

        XCTAssertTrue(created.openedAsOwner)
        XCTAssertTrue(created.isPublicKey)
        XCTAssertFalse(created.permsMismatch)
    }

    func test_onlyKeysThatMayEncipherOrAgreeCanProtect() throws {
        let ec = try XCTUnwrap(PdfCertificate(Pki.instance.leafEc))
        let signOnly = try XCTUnwrap(PdfCertificate(PdfDigitalId.create("Signer", nil, DateTimeOffset(2025, 1, 1, 0, 0, 0), keyBits: 2048)))

        XCTAssertTrue(PdfRecipient.canProtect(PublicKeyFiles.alice))
        XCTAssertFalse(PdfRecipient.canProtect(ec))
        XCTAssertFalse(PdfRecipient.canProtect(signOnly))
    }

    func test_aCertificateWithoutKeyUsageCanProtect() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(try XCTUnwrap(SecKeyCopyPublicKey(privateKey)), nil) as Data?)
        let der = TestCertificate.der("Open", publicKey: [UInt8](pkcs1), withUsage: false) { tbs in
            [UInt8](SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, nil) as Data? ?? Data())
        }
        let open = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(der) as CFData))

        XCTAssertTrue(PdfRecipient.canProtect(PdfCertificate(certificate: open)))
    }

    func test_aCertificateThatCannotProtectIsRefused() throws {
        let ec = try XCTUnwrap(PdfCertificate(Pki.instance.leafEc))

        XCTAssertThrowsError(try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice), PdfRecipient(ec)], .aes256)) { error in
            XCTAssertEqual((error as? PdfReadException)?.message, "This certificate cannot be used to protect a file. Choose a certificate with an RSA or a P-256 or P-384 key.")
        }
    }

    func test_readerDecryptsWhatTheCreatorEncrypted() throws {
        for strength in PdfCryptStrength.allCases {
            let created = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], strength)
            let reader = try XCTUnwrap(PdfSecurity.openPublicKey(created.dictionary, PublicKeyFiles.alice))
            let plain = Array("BT (text) Tj ET".utf8)

            XCTAssertEqual(reader.decryptStream(7, 0, created.encryptStream(7, 0, plain, PdfDictionary()), PdfDictionary()), plain)
            XCTAssertEqual(reader.decryptString(8, 0, created.encryptString(8, 0, plain)), plain)
            XCTAssertEqual(reader.revision, strength == .aes256 ? 6 : 4)
        }
    }
}
#endif
