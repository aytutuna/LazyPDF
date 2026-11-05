import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/RevisionTests.cs: the same cases. Each [Theory] is one test that loops
// over the cases.

final class RevisionTests: XCTestCase {
    private let id = SyntheticEncryption.id

    // V, R, key bits, crypt filter method (nil before V 4 and for the cipher of V 5).
    private let cases: [(v: Int, r: Int, bits: Int, cfm: String?)] = [
        (1, 2, 40, nil),
        (2, 3, 128, nil),
        (2, 3, 64, nil),
        (4, 4, 128, "V2"),
        (4, 4, 128, "AESV2"),
        (5, 5, 256, "AESV3"),
        (5, 6, 256, "AESV3"),
    ]

    private func build(_ v: Int, _ r: Int, _ bits: Int, _ cfm: String?, _ user: String, _ owner: String) -> BuiltEncryption {
        v == 5 ? SyntheticEncryption.modern(r, user, owner) : SyntheticEncryption.legacy(v, r, bits, user, owner, cfm: cfm)
    }

    private func stored(_ built: BuiltEncryption, _ cfm: String?, _ number: Int, _ generation: Int, _ plain: [UInt8]) -> [UInt8] {
        switch cfm {
        case "AESV3": return SyntheticEncryption.storeAes256(built.fileKey, plain)
        case "AESV2": return SyntheticEncryption.storeAes128(built.fileKey, number, generation, plain)
        default: return SyntheticEncryption.storeRc4(built.fileKey, number, generation, plain)
        }
    }

    func test_userAndOwnerPasswordsOpen() throws {
        for (v, r, bits, cfm) in cases {
            let name = "V \(v) R \(r) \(bits) \(cfm ?? "-")"
            let built = build(v, r, bits, cfm, "user pw", "owner pw")

            let user = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "user pw"), name)
            let owner = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "owner pw"), name)

            XCTAssertFalse(user.openedAsOwner, name)
            XCTAssertEqual(user.revision, r, name)
            XCTAssertTrue(owner.openedAsOwner, name)
        }
    }

    func test_wrongPasswordsGiveNull() throws {
        for (v, r, bits, cfm) in cases {
            let name = "V \(v) R \(r) \(bits) \(cfm ?? "-")"
            let built = build(v, r, bits, cfm, "user pw", "owner pw")

            XCTAssertNil(try PdfSecurity.open(built.dictionary, id, "user"), name)
            XCTAssertNil(try PdfSecurity.open(built.dictionary, id, "user pw "), name)
            XCTAssertNil(try PdfSecurity.open(built.dictionary, id, ""), name)
            XCTAssertNil(try PdfSecurity.open(built.dictionary, id, nil), name)
        }
    }

    func test_emptyUserPasswordOpensWithNullOrEmpty() throws {
        for (v, r, bits, cfm) in cases {
            let name = "V \(v) R \(r) \(bits) \(cfm ?? "-")"
            let built = build(v, r, bits, cfm, "", "owner pw")

            XCTAssertFalse(try XCTUnwrap(PdfSecurity.open(built.dictionary, id, nil), name).openedAsOwner, name)
            XCTAssertFalse(try XCTUnwrap(PdfSecurity.open(built.dictionary, id, ""), name).openedAsOwner, name)
            XCTAssertTrue(try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "owner pw"), name).openedAsOwner, name)
        }
    }

    func test_decryptsWhatAWriterStored() throws {
        for (v, r, bits, cfm) in cases {
            let name = "V \(v) R \(r) \(bits) \(cfm ?? "-")"
            let built = build(v, r, bits, cfm, "u", "o")
            let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"), name)
            let plain = Array("(Hello) 0 0 Td".utf8)

            XCTAssertEqual(security.decryptString(12, 0, stored(built, cfm, 12, 0, plain)), plain, name)
            XCTAssertEqual(security.decryptStream(300, 2, stored(built, cfm, 300, 2, plain), PdfDictionary()), plain, name)
            XCTAssertEqual(security.decryptString(70000, 0, stored(built, cfm, 70000, 0, plain)), plain, name)
        }
    }

    func test_encryptThenDecryptRoundTrips() throws {
        var random = SeededRandom(5)
        let big = random.bytes(100_000)
        for (v, r, bits, cfm) in cases {
            let name = "V \(v) R \(r) \(bits) \(cfm ?? "-")"
            let built = build(v, r, bits, cfm, "u", "o")
            let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"), name)

            for plain in [[], [1], Array(big.prefix(16)), Array(big.prefix(17)), big] as [[UInt8]] {
                let stream = security.encryptStream(8, 0, plain, PdfDictionary())
                XCTAssertEqual(security.decryptStream(8, 0, stream, PdfDictionary()), plain, name)
                let text = security.encryptString(9, 1, plain)
                XCTAssertEqual(security.decryptString(9, 1, text), plain, name)
            }
        }
    }

    func test_encryptedFormMatchesWhatTheSpecProduces() throws {
        for (v, r, bits, cfm) in cases {
            let name = "V \(v) R \(r) \(bits) \(cfm ?? "-")"
            let built = build(v, r, bits, cfm, "u", "o")
            let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"), name)
            let plain = Array("same bytes".utf8)

            let encrypted = security.encryptString(21, 0, plain)

            if cfm == nil || cfm == "V2" {
                XCTAssertEqual(encrypted, stored(built, cfm, 21, 0, plain), name)
            } else {
                // AES takes a random IV, so only the size is fixed: the IV and one padded block.
                XCTAssertEqual(encrypted.count, 32, name)
                XCTAssertNotEqual(Array(encrypted[16..<26]), plain, name)
            }
        }
    }

    func test_objectsAreKeyedByNumberAndGeneration() throws {
        for (v, r, bits, cfm) in [(1, 2, 40, nil), (4, 4, 128, "V2"), (4, 4, 128, "AESV2")] as [(Int, Int, Int, String?)] {
            let name = "V \(v) R \(r) \(bits) \(cfm ?? "-")"
            let built = build(v, r, bits, cfm, "u", "o")
            let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"), name)
            let plain = Array("0123456789abcdef0123".utf8)
            let data = stored(built, cfm, 4, 0, plain)

            XCTAssertEqual(security.decryptString(4, 0, data), plain, name)
            XCTAssertNotEqual(security.decryptString(5, 0, data), plain, name)
            XCTAssertNotEqual(security.decryptString(4, 1, data), plain, name)
        }
    }

    func test_permissionsAreReadFromP() throws {
        let p = Int(Int32(bitPattern: 0xFFFFF0C0) | 4 | 256)
        let built = SyntheticEncryption.legacy(2, 3, 128, "u", "o", p: p)

        let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"))

        XCTAssertEqual(security.permissions, [.print, .fillForms])
    }

    func test_permissionsOfAnOwnerAreStillTheFilesFlags() throws {
        let built = SyntheticEncryption.modern(6, "u", "o", p: Int(Int32(bitPattern: 0xFFFFF0C0) | 16))

        let owner = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "o"))

        XCTAssertTrue(owner.openedAsOwner)
        XCTAssertEqual(owner.permissions, .copy)
    }

    func test_pAsAnUnsignedNumberIsTheSameAsNegative() throws {
        let built = SyntheticEncryption.legacy(2, 3, 128, "u", "o")
        built.dictionary["P"] = PdfNumber("4294967292")

        let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"))

        XCTAssertEqual(security.permissions, .all)
    }

    func test_encryptMetadataFalseChangesTheKeyAndIsReported() throws {
        let built = SyntheticEncryption.legacy(4, 4, 128, "u", "o", encryptMetadata: false, cfm: "AESV2")

        let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"))

        XCTAssertFalse(security.encryptMetadata)
        let plain = Array("text".utf8)
        XCTAssertEqual(security.decryptString(3, 0, SyntheticEncryption.storeAes128(built.fileKey, 3, 0, plain)), plain)
    }

    func test_encryptMetadataIsIgnoredBeforeR4() throws {
        let built = SyntheticEncryption.legacy(2, 3, 128, "u", "o")
        built.dictionary["EncryptMetadata"] = PdfBoolean(false)

        XCTAssertTrue(try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u")).encryptMetadata)
    }

    func test_stringsAndStreamsCanUseDifferentFilters() throws {
        let built = SyntheticEncryption.legacy(4, 4, 128, "u", "o", cfm: "AESV2", strF: "StdCF", stmF: "Rc4CF")
        let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"))
        let plain = Array("mixed".utf8)

        XCTAssertEqual(security.decryptString(6, 0, SyntheticEncryption.storeAes128(built.fileKey, 6, 0, plain)), plain)
        XCTAssertEqual(security.decryptStream(6, 0, SyntheticEncryption.storeRc4(built.fileKey, 6, 0, plain), PdfDictionary()), plain)
    }

    func test_identityFiltersLeaveDataAlone() throws {
        let built = SyntheticEncryption.legacy(4, 4, 128, "u", "o", cfm: "AESV2", strF: "Identity", stmF: "Identity")
        let security = try XCTUnwrap(PdfSecurity.open(built.dictionary, id, "u"))
        let plain = Array("clear".utf8)

        XCTAssertEqual(security.decryptString(1, 0, plain), plain)
        XCTAssertEqual(security.decryptStream(1, 0, plain, PdfDictionary()), plain)
        XCTAssertEqual(security.encryptString(1, 0, plain), plain)
    }

    func test_passwordOutsideLatin1FailsCleanlyOnLegacy() throws {
        let built = SyntheticEncryption.legacy(2, 3, 128, "u", "o")

        XCTAssertNil(try PdfSecurity.open(built.dictionary, id, "\u{4E2D}\u{6587}"))
    }

    func test_latin1PasswordOpensLegacyFiles() throws {
        let built = SyntheticEncryption.legacy(2, 3, 128, "caf\u{E9}", "o")

        XCTAssertNotNil(try PdfSecurity.open(built.dictionary, id, "caf\u{E9}"))
    }

    func test_modernPasswordsAreSaslPrepared() throws {
        for r in [5, 6] {
            // The file holds the prepared form "a b"; the typed one has a soft hyphen and a no-break space.
            let built = SyntheticEncryption.modern(r, "a b", "o")

            XCTAssertNotNil(try PdfSecurity.open(built.dictionary, id, "a\u{AD}\u{A0}b"), "R \(r)")
        }
    }

    func test_modernPasswordLongerThan127BytesIsCut() throws {
        let password = String(repeating: "x", count: 127)
        let built = SyntheticEncryption.modern(6, password, "o")

        XCTAssertNotNil(try PdfSecurity.open(built.dictionary, id, password + "yyyy"))
    }
}
