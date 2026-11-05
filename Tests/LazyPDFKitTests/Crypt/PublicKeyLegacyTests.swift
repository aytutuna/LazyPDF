#if canImport(Security)
import XCTest
import Security
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/PublicKeyLegacyTests.cs: the same cases. Where the C# opens the
// recipient with EnvelopedCms, this opens it with PdfCms and the system's RSA, the same steps by hand.

final class PublicKeyLegacyTests: XCTestCase {
    private let text = Array("secret".utf8)

    func test_s4WithVersionFourKeepsItsRecipientsInTheFilter() throws {
        let created = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], .aes128)
        let dictionary = created.dictionary.copy()
        dictionary["SubFilter"] = PdfName("adbe.pkcs7.s4")

        let reader = try XCTUnwrap(PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice))

        XCTAssertEqual(reader.decryptString(4, 0, created.encryptString(4, 0, text)), text)
    }

    func test_versionOneIsFortyBitWhateverLengthSaysAndIsRead() throws {
        let (dictionary, cipher) = try rc4File("adbe.pkcs7.s3", 1, 128)

        let reader = try XCTUnwrap(PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice))

        XCTAssertEqual(reader.decryptString(4, 0, cipher), text)
    }

    func test_aStrayEncryptMetadataIsIgnoredBeforeVersionFour() throws {
        let (dictionary, cipher) = try rc4File("adbe.pkcs7.s4", 2, 40)
        dictionary.add("EncryptMetadata", PdfBoolean(false))

        let reader = try XCTUnwrap(PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice))

        XCTAssertEqual(reader.decryptString(4, 0, cipher), text)
        XCTAssertTrue(reader.encryptMetadata)
    }

    func test_theFilterWithTheRecipientsMayBeNamedByAnyOfTheThreeEntries() throws {
        for key in ["StmF", "StrF", "EFF"] {
            let created = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], .aes128)
            let dictionary = created.dictionary.copy()
            for other in ["StmF", "StrF", "EFF"] { dictionary[other] = PdfName("Identity") }
            dictionary[key] = PdfName("DefaultCryptFilter")

            XCTAssertNotNil(try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice), key)
        }
    }

    func test_noEntryNamingAFilterWithRecipientsIsDamaged() throws {
        let created = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], .aes128)
        let dictionary = created.dictionary.copy()
        dictionary["StmF"] = PdfName("Identity")
        dictionary["StrF"] = PdfName("Identity")

        XCTAssertThrowsError(try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice)) { error in
            XCTAssertEqual((error as? PdfReadException)?.problem, .damaged)
        }
    }

    // A file with 40-bit RC4 and one recipient, and the string "secret" of object 4 encrypted for it as the format has it.
    private func rc4File(_ subFilter: String, _ version: Int, _ length: Int) throws -> (dictionary: PdfDictionary, cipher: [UInt8]) {
        let sealedAes = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], .aes128)
        let cf = try XCTUnwrap(sealedAes.dictionary["CF"] as? PdfDictionary)
        let filter = try XCTUnwrap(cf["DefaultCryptFilter"] as? PdfDictionary)
        let stored = try XCTUnwrap(filter["Recipients"] as? PdfArray)
        let dictionary = PdfDictionary()
        dictionary.add("Filter", PdfName("Adobe.PubSec"))
        dictionary.add("SubFilter", PdfName(subFilter))
        dictionary.add("V", PdfNumber(version))
        dictionary.add("Length", PdfNumber(length))
        dictionary.add("Recipients", stored)

        let entry = try XCTUnwrap(stored.items.first as? PdfString).bytes
        let envelope = try XCTUnwrap(PdfCms.decode(entry))
        let recipient = try XCTUnwrap(envelope.recipients.first)
        let key = try XCTUnwrap(PublicKeyFiles.alice.privateKey)
        let wrapped = try XCTUnwrap(SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, Data(recipient.encryptedKey) as CFData, nil) as Data?)
        let content = try XCTUnwrap(PdfCms.decryptContent(envelope, key: [UInt8](wrapped)))
        let fileKey = Array(Sha1.hash(Array(content.prefix(20)) + entry).prefix(5))
        let input = fileKey + [4, 0, 0, 0, 0]
        return (dictionary, Rc4.apply(Array(Md5.hash(input).prefix(10)), text))
    }
}
#endif
