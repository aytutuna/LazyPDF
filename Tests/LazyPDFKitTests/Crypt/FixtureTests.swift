import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/FixtureTests.cs: the same cases, reading the same files.

final class FixtureTests: XCTestCase {
    // The crypt-* files are pypdf's, user "secret" and owner "owner".
    func test_userPasswordOpensAndDecryptsTheContent() throws {
        for (name, revision) in [("crypt-rc4-40.pdf", 2), ("crypt-aes128.pdf", 4), ("crypt-aes256-r5.pdf", 5), ("crypt-aes256.pdf", 6)] {
            let file = try EncryptedFixture.load(name)
            let security = try XCTUnwrap(PdfSecurity.open(file.encrypt, file.id, "secret"), name)

            XCTAssertFalse(security.openedAsOwner, name)
            XCTAssertEqual(security.revision, revision, name)
            let plain = security.decryptStream(4, 0, file.content, file.contentDictionary)
            XCTAssertEqual(Latin1.string(plain), EncryptedFixture.plainContent, name)
        }
    }

    func test_ownerPasswordOpensAsOwner() throws {
        for name in ["crypt-rc4-40.pdf", "crypt-aes128.pdf", "crypt-aes256-r5.pdf", "crypt-aes256.pdf"] {
            let file = try EncryptedFixture.load(name)
            let security = try XCTUnwrap(PdfSecurity.open(file.encrypt, file.id, "owner"), name)

            XCTAssertTrue(security.openedAsOwner, name)
            let plain = security.decryptStream(4, 0, file.content, file.contentDictionary)
            XCTAssertEqual(Latin1.string(plain), EncryptedFixture.plainContent, name)
        }
    }

    func test_wrongOrMissingPasswordGivesNull() throws {
        for name in ["locked.pdf", "crypt-rc4-40.pdf", "crypt-aes128.pdf", "crypt-aes256-r5.pdf", "crypt-aes256.pdf"] {
            let file = try EncryptedFixture.load(name)

            XCTAssertNil(try PdfSecurity.open(file.encrypt, file.id, "Secret"), name)
            XCTAssertNil(try PdfSecurity.open(file.encrypt, file.id, ""), name)
            XCTAssertNil(try PdfSecurity.open(file.encrypt, file.id, nil), name)
        }
    }

    func test_ownerOnlyFilesOpenWithTheEmptyPassword() throws {
        for (name, revision) in [("owner-only-rc4.pdf", 3), ("owner-only-aes.pdf", 4)] {
            let file = try EncryptedFixture.load(name)

            for empty in [nil, ""] as [String?] {
                let security = try XCTUnwrap(PdfSecurity.open(file.encrypt, file.id, empty), name)
                XCTAssertFalse(security.openedAsOwner, name)
                XCTAssertEqual(security.revision, revision, name)
                let plain = security.decryptStream(4, 0, file.content, file.contentDictionary)
                XCTAssertEqual(Latin1.string(plain), EncryptedFixture.plainContent, name)
            }
            XCTAssertTrue(try XCTUnwrap(PdfSecurity.open(file.encrypt, file.id, "owner"), name).openedAsOwner, name)
        }
    }

    // RC4-128 (V 2 R 3) with one password for both roles, so it opens as owner.
    func test_lockedFileOpensWithItsPassword() throws {
        let file = try EncryptedFixture.load("locked.pdf")
        let security = try XCTUnwrap(PdfSecurity.open(file.encrypt, file.id, "secret"))

        XCTAssertTrue(security.openedAsOwner)
        XCTAssertEqual(security.revision, 3)
        let plain = security.decryptStream(4, 0, file.content, file.contentDictionary)
        XCTAssertEqual(Latin1.string(plain), EncryptedFixture.plainContent)
        XCTAssertNil(try PdfSecurity.open(file.encrypt, file.id, ""))
    }

    func test_permissionsComeFromP() throws {
        let file = try EncryptedFixture.load("locked.pdf")
        let security = try XCTUnwrap(PdfSecurity.open(file.encrypt, file.id, "secret"))

        XCTAssertEqual(security.permissions, PdfPermissions.all)
        XCTAssertTrue(security.encryptMetadata)
    }

    func test_wrongIdFailsTheLegacyCheck() throws {
        let file = try EncryptedFixture.load("locked.pdf")

        XCTAssertNil(try PdfSecurity.open(file.encrypt, [1, 2, 3], "secret"))
    }
}
