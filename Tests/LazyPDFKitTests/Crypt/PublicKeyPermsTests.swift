import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/PublicKeyPermsTests.cs: the same cases except DocumentExposesTheFact,
// which needs PdfDocument and is in Document/PermsDocumentTests.swift.

final class PublicKeyPermsTests: XCTestCase {
    private let id = SyntheticEncryption.id

    private func modern(_ strength: PdfCryptStrength = .aes256) -> PdfDictionary {
        PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: [.print, .copy],
                           strength: strength, firstId: id).dictionary.copy()
    }

    private func open(_ dictionary: PdfDictionary) throws -> PdfSecurity {
        try XCTUnwrap(PdfSecurity.open(dictionary, id, "user"))
    }

    func test_untouchedR6IsFine() throws {
        XCTAssertFalse(try open(modern()).permsMismatch)
    }

    func test_changedPermissionsAreFlaggedAndTheFileStillOpens() throws {
        let dictionary = modern()
        dictionary["P"] = PdfNumber(-4)

        let security = try open(dictionary)

        XCTAssertTrue(security.permsMismatch)
        XCTAssertEqual(security.permissions, .all)
    }

    func test_changedMetadataFlagIsFlagged() throws {
        let dictionary = modern()
        dictionary["EncryptMetadata"] = PdfBoolean(false)

        XCTAssertTrue(try open(dictionary).permsMismatch)
    }

    func test_damagedPermsIsFlagged() throws {
        let dictionary = modern()
        var perms = try XCTUnwrap(dictionary["Perms"] as? PdfString).bytes
        perms[3] ^= 0x10
        dictionary["Perms"] = PdfString(bytes: perms, isHex: true)

        XCTAssertTrue(try open(dictionary).permsMismatch)
    }

    func test_shortOrMissingPermsIsFlagged() throws {
        for length in [0, 8] {
            let dictionary = modern()
            if length == 0 {
                dictionary.remove("Perms")
            } else {
                dictionary["Perms"] = PdfString(bytes: [UInt8](repeating: 0, count: length), isHex: true)
            }

            XCTAssertTrue(try open(dictionary).permsMismatch, "\(length)")
        }
    }

    func test_permsOfAnotherFileKeyIsFlagged() throws {
        let dictionary = modern()
        dictionary["Perms"] = modern()["Perms"]

        XCTAssertTrue(try open(dictionary).permsMismatch)
    }

    func test_ownerOpenChecksToo() throws {
        let dictionary = modern()
        dictionary["P"] = PdfNumber(-4)

        XCTAssertTrue(try XCTUnwrap(PdfSecurity.open(dictionary, id, "owner")).permsMismatch)
    }

    func test_olderRevisionsAreNotChecked() throws {
        XCTAssertFalse(try XCTUnwrap(PdfSecurity.open(SyntheticEncryption.modern(5, "u", "o").dictionary, id, "u")).permsMismatch)
        XCTAssertFalse(try open(modern(.aes128)).permsMismatch)
    }

    func test_r6WithNoPermsAtAllIsFlagged() throws {
        XCTAssertTrue(try XCTUnwrap(PdfSecurity.open(SyntheticEncryption.modern(6, "u", "o").dictionary, id, "u")).permsMismatch)
    }

    func test_fixtureFromAnotherWriterIsFine() throws {
        let fixture = try EncryptedFixture.load("crypt-aes256.pdf")

        XCTAssertFalse(try XCTUnwrap(PdfSecurity.open(fixture.encrypt, fixture.id, "secret")).permsMismatch)
    }
}
