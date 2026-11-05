import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/StreamRulesTests.cs: the same cases. Assert.Same on the returned array
// is an equality here: a Swift array has no identity, and the encrypted form always differs from the plain one.

final class StreamRulesTests: XCTestCase {
    private let plain = Array("stream bytes, long enough to span blocks".utf8)

    private func parse(_ text: String) throws -> PdfDictionary {
        try XCTUnwrap(try PdfLexer(PdfArrayBytes(Array(text.utf8))).readObject() as? PdfDictionary)
    }

    private func open(encryptMetadata: Bool = true) throws -> (security: PdfSecurity, built: BuiltEncryption) {
        let built = SyntheticEncryption.legacy(4, 4, 128, "u", "o", encryptMetadata: encryptMetadata, cfm: "AESV2")
        return (try XCTUnwrap(PdfSecurity.open(built.dictionary, SyntheticEncryption.id, "u")), built)
    }

    func test_xRefStreamsAreNeverEncrypted() throws {
        let (security, _) = try open()
        let dictionary = try parse("<</Type /XRef /Size 3>>")

        XCTAssertEqual(security.encryptStream(5, 0, plain, dictionary), plain)
        XCTAssertEqual(security.decryptStream(5, 0, plain, dictionary), plain)
    }

    func test_metadataIsClearOnlyWhenEncryptMetadataIsFalse() throws {
        let metadata = try parse("<</Type /Metadata /Subtype /XML>>")
        let (clear, _) = try open(encryptMetadata: false)
        let (encrypted, _) = try open()

        XCTAssertEqual(clear.decryptStream(5, 0, plain, metadata), plain)
        XCTAssertEqual(clear.encryptStream(5, 0, plain, metadata), plain)
        XCTAssertNotEqual(encrypted.encryptStream(5, 0, plain, metadata), plain)
    }

    func test_cryptFilterNamingIdentityLeavesTheStreamAlone() throws {
        let (security, _) = try open()

        XCTAssertEqual(security.decryptStream(5, 0, plain, try parse("<</Filter /Crypt /DecodeParms <</Name /Identity>>>>")), plain)
        XCTAssertEqual(security.decryptStream(5, 0, plain, try parse("<</Filter /Crypt>>")), plain)
        XCTAssertEqual(security.decryptStream(5, 0, plain,
                                              try parse("<</Filter [/Crypt /FlateDecode] /DecodeParms [<</Name /Identity>> null]>>")), plain)
    }

    func test_cryptFilterNamingAnotherFilterUsesIt() throws {
        let built = SyntheticEncryption.legacy(4, 4, 128, "u", "o", cfm: "AESV2")
        let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, SyntheticEncryption.id, "u"))
        let stored = SyntheticEncryption.storeRc4(built.fileKey, 7, 0, plain)

        let decrypted = security.decryptStream(7, 0, stored, try parse("<</Filter /Crypt /DecodeParms <</Name /Rc4CF>>>>"))

        XCTAssertEqual(decrypted, plain)
    }

    func test_filtersWithoutCryptDecryptWithTheStreamFilter() throws {
        let (security, built) = try open()
        let stored = SyntheticEncryption.storeAes128(built.fileKey, 7, 0, plain)

        XCTAssertEqual(security.decryptStream(7, 0, stored, try parse("<</Filter /FlateDecode>>")), plain)
        XCTAssertEqual(security.decryptStream(7, 0, stored, try parse("<</Filter [/ASCII85Decode /FlateDecode]>>")), plain)
    }

    func test_aesDataTooShortForABlockIsEmpty() throws {
        let (security, _) = try open()

        for length in [0, 5, 16, 17, 31] {
            XCTAssertTrue(security.decryptString(1, 0, [UInt8](repeating: 0, count: length)).isEmpty, "\(length)")
        }
    }

    func test_aesTrailingPartialBlockIsDropped() throws {
        let (security, built) = try open()
        let stored = SyntheticEncryption.storeAes128(built.fileKey, 1, 0, plain) + [1, 2, 3]

        XCTAssertEqual(security.decryptString(1, 0, stored), plain)
    }

    func test_aesBadPaddingTailKeepsTheDecryptedBlocks() throws {
        let (security, built) = try open()
        var stored = SyntheticEncryption.storeAes128(built.fileKey, 1, 0, plain)
        // Another cipher text block in front of the last one makes the final plain block garbage.
        stored[stored.count - 17] ^= 0x55

        let decrypted = security.decryptString(1, 0, stored)

        XCTAssertEqual(decrypted.count, stored.count - 16)
        XCTAssertEqual(Array(decrypted.prefix(16)), Array(plain.prefix(16)))
    }

    func test_aesGarbageDoesNotThrow() throws {
        let (security, _) = try open()
        var random = SeededRandom(3)
        let garbage = random.bytes(64)

        XCTAssertLessThanOrEqual(security.decryptStream(1, 0, garbage, PdfDictionary()).count, 48)
    }

    func test_rc4OfEmptyDataIsEmpty() throws {
        let built = SyntheticEncryption.legacy(2, 3, 128, "u", "o")
        let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, SyntheticEncryption.id, "u"))

        XCTAssertTrue(security.decryptString(1, 0, []).isEmpty)
        XCTAssertTrue(security.encryptString(1, 0, []).isEmpty)
    }
}
