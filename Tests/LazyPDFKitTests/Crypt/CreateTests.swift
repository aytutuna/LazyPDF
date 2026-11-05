import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/CreateTests.cs: the same cases. A seeded System.Random is a SeededRandom.

final class CreateTests: XCTestCase {
    private let id = SyntheticEncryption.id

    // The dictionary as a file holds it: written out and read back.
    private func reparsed(_ security: PdfSecurity) throws -> PdfDictionary {
        let lexer = PdfLexer(PdfArrayBytes(Array(security.dictionary.description.utf8)))
        return try XCTUnwrap(try lexer.readObject() as? PdfDictionary)
    }

    func test_createdFileOpensWithEachPassword() throws {
        for (strength, revision) in [(PdfCryptStrength.aes256, 6), (PdfCryptStrength.aes128, 4)] {
            let created = PdfSecurity.create(userPassword: "user", ownerPassword: "owner",
                                             permissions: [.print, .copy], strength: strength, firstId: id)
            let dictionary = try reparsed(created)

            let user = try XCTUnwrap(PdfSecurity.open(dictionary, id, "user"), "\(strength)")
            let owner = try XCTUnwrap(PdfSecurity.open(dictionary, id, "owner"), "\(strength)")

            XCTAssertEqual(created.revision, revision)
            XCTAssertFalse(user.openedAsOwner)
            XCTAssertEqual(user.permissions, [.print, .copy])
            XCTAssertTrue(owner.openedAsOwner)
            XCTAssertNil(try PdfSecurity.open(dictionary, id, "other"))
            XCTAssertNil(try PdfSecurity.open(dictionary, id, ""))
        }
    }

    func test_readerDecryptsWhatTheCreatorEncrypted() throws {
        for strength in PdfCryptStrength.allCases {
            let created = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all,
                                             strength: strength, firstId: id)
            let reader = try XCTUnwrap(PdfSecurity.open(try reparsed(created), id, "user"))
            let plain = Array("BT /F1 12 Tf (text) Tj ET".utf8)

            XCTAssertEqual(reader.decryptStream(9, 0, created.encryptStream(9, 0, plain, PdfDictionary()), PdfDictionary()), plain)
            XCTAssertEqual(reader.decryptString(10, 0, created.encryptString(10, 0, plain)), plain)
            XCTAssertEqual(created.decryptString(10, 0, reader.encryptString(10, 0, plain)), plain)
        }
    }

    func test_aes256DictionaryHasTheR6Shape() throws {
        let dictionary = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all,
                                            strength: .aes256, firstId: id).dictionary

        XCTAssertEqual((dictionary["V"] as? PdfNumber)?.value, 5)
        XCTAssertEqual((dictionary["R"] as? PdfNumber)?.value, 6)
        XCTAssertEqual((dictionary["O"] as? PdfString)?.bytes.count, 48)
        XCTAssertEqual((dictionary["U"] as? PdfString)?.bytes.count, 48)
        XCTAssertEqual((dictionary["OE"] as? PdfString)?.bytes.count, 32)
        XCTAssertEqual((dictionary["UE"] as? PdfString)?.bytes.count, 32)
        XCTAssertEqual((dictionary["Perms"] as? PdfString)?.bytes.count, 16)
        XCTAssertEqual((dictionary["StmF"] as? PdfName)?.value, "StdCF")
    }

    func test_reservedBitsOfPAreSet() throws {
        let dictionary = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .none,
                                            strength: .aes128, firstId: id).dictionary

        let p = try XCTUnwrap((dictionary["P"] as? PdfNumber)?.integer)
        XCTAssertEqual(p, Int(Int32(bitPattern: 0xFFFFF0C0)))
    }

    func test_everyPermissionSurvivesTheTrip() throws {
        let flags: [PdfPermissions] = [.print, .modify, .copy, .annotate, .fillForms, .extractForAccessibility,
                                       .assemble, .printHighQuality]
        for strength in PdfCryptStrength.allCases {
            for flag in flags {
                let created = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: flag,
                                                 strength: strength, firstId: id)

                let opened = try XCTUnwrap(PdfSecurity.open(try reparsed(created), id, "u"))
                XCTAssertEqual(opened.permissions, flag, "\(strength) \(flag.rawValue)")
            }
        }
    }

    func test_emptyOwnerPasswordIsReplacedByUnknownBytes() throws {
        for strength in PdfCryptStrength.allCases {
            let created = PdfSecurity.create(userPassword: "user", ownerPassword: "", permissions: .none,
                                             strength: strength, firstId: id)
            let dictionary = try reparsed(created)

            XCTAssertNil(try PdfSecurity.open(dictionary, id, ""), "\(strength)")
            XCTAssertFalse(try XCTUnwrap(PdfSecurity.open(dictionary, id, "user")).openedAsOwner, "\(strength)")
        }
    }

    func test_emptyUserPasswordOpensForAnyone() throws {
        for strength in PdfCryptStrength.allCases {
            let created = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .print,
                                             strength: strength, firstId: id)
            let dictionary = try reparsed(created)

            let reader = try XCTUnwrap(PdfSecurity.open(dictionary, id, nil))
            XCTAssertFalse(reader.openedAsOwner, "\(strength)")
            XCTAssertEqual(reader.permissions, .print, "\(strength)")
            XCTAssertTrue(try XCTUnwrap(PdfSecurity.open(dictionary, id, "owner")).openedAsOwner, "\(strength)")
        }
    }

    func test_sameSeedGivesTheSameFile() {
        for strength in PdfCryptStrength.allCases {
            let a = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all, strength: strength,
                                       firstId: id, random: SeededRandom(11))
            let b = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all, strength: strength,
                                       firstId: id, random: SeededRandom(11))
            let c = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all, strength: strength,
                                       firstId: id, random: SeededRandom(12))
            let plain = Array("abc".utf8)

            XCTAssertEqual(a.dictionary.description, b.dictionary.description, "\(strength)")
            XCTAssertEqual(a.encryptString(1, 0, plain), b.encryptString(1, 0, plain), "\(strength)")
            XCTAssertNotEqual(a.encryptString(1, 0, plain), a.encryptString(1, 0, plain), "\(strength)")
            if strength == .aes256 { XCTAssertNotEqual(a.dictionary.description, c.dictionary.description) }
        }
    }

    func test_unseededCreatesDiffer() {
        let a = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all, strength: .aes256, firstId: id)
        let b = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all, strength: .aes256, firstId: id)

        XCTAssertNotEqual(a.dictionary.description, b.dictionary.description)
    }

    func test_defaultStrengthIsAes256() {
        XCTAssertEqual(PdfCryptStrength.allCases.first, .aes256)
    }

    func test_aes128KeyDependsOnTheId() throws {
        let created = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all,
                                         strength: .aes128, firstId: id)

        XCTAssertNil(try PdfSecurity.open(try reparsed(created), [9, 9, 9], "u"))
    }

    func test_composedAndDecomposedPasswordsBothOpenAes256() throws {
        let created = PdfSecurity.create(userPassword: "\u{E9}t\u{E9}", ownerPassword: "o", permissions: .all,
                                         strength: .aes256, firstId: id)
        let dictionary = try reparsed(created)

        XCTAssertNotNil(try PdfSecurity.open(dictionary, id, "\u{E9}t\u{E9}"))
        XCTAssertNotNil(try PdfSecurity.open(dictionary, id, "e\u{301}te\u{301}"))
    }

    func test_anOpenedFileKeepsItsOwnDictionary() throws {
        let created = PdfSecurity.create(userPassword: "u", ownerPassword: "o", permissions: .all,
                                         strength: .aes256, firstId: id)
        let dictionary = try reparsed(created)

        XCTAssertTrue(try XCTUnwrap(PdfSecurity.open(dictionary, id, "u")).dictionary === dictionary)
    }
}
