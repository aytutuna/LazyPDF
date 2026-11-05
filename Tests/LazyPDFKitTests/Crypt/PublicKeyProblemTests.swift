#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/PublicKeyProblemTests.cs: the same cases from UnknownSubFilterIsUnsupported
// on. The seven before it open a PdfDocument (NoCertificateNeedsOne, CertificateOfSomeoneElseNeedsTheRightOne,
// RightCertificateWithoutItsPrivateKeyIsNotEnough, ProblemIsTheSameForBothStrengths, PasswordFileGivenACertificate
// StillWantsAPassword, PasswordFileWithAnEmptyUserPasswordOpensWithACertificate, PlainFileIgnoresTheCertificate) and
// are in Document/PublicKeyProblemOpenTests.swift. The two tests at the end are their handler-level halves: the answer that the
// document turns into CertificateRequired. DamagedRecipientsAreNotACrash has no C# twin.

final class PublicKeyProblemTests: XCTestCase {
    private func problem(_ open: () throws -> PdfSecurity?, file: StaticString = #filePath, line: UInt = #line) -> PdfReadProblem? {
        do {
            _ = try open()
            XCTFail("It opened.", file: file, line: line)
        } catch let error as PdfReadException {
            return error.problem
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
        return nil
    }

    private func sealed(_ strength: PdfCryptStrength = .aes256) throws -> PdfDictionary {
        try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], strength).dictionary.copy()
    }

    private func filterOf(_ dictionary: PdfDictionary) throws -> PdfDictionary {
        let cf = try XCTUnwrap(dictionary["CF"] as? PdfDictionary)
        return try XCTUnwrap(cf["DefaultCryptFilter"] as? PdfDictionary)
    }

    private func openProblem(_ dictionary: PdfDictionary) -> PdfReadProblem? {
        problem { try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice) }
    }

    func test_unknownSubFilterIsUnsupported() throws {
        let dictionary = try sealed()
        dictionary["SubFilter"] = PdfName("adbe.pkcs7.s9")

        XCTAssertEqual(openProblem(dictionary), .unsupported)
    }

    func test_versionThatDoesNotFitTheSubFilterIsUnsupported() throws {
        let dictionary = try sealed()
        dictionary["V"] = PdfNumber(2)

        XCTAssertEqual(openProblem(dictionary), .unsupported)
    }

    func test_cipherThatDoesNotFitTheVersionIsUnsupported() throws {
        let dictionary = try sealed()
        try filterOf(dictionary)["CFM"] = PdfName("AESV2")

        XCTAssertEqual(openProblem(dictionary), .unsupported)
    }

    func test_missingRecipientsIsDamaged() throws {
        let dictionary = try sealed()
        try filterOf(dictionary).remove("Recipients")

        XCTAssertEqual(openProblem(dictionary), .damaged)
    }

    func test_missingCryptFilterIsDamaged() throws {
        let dictionary = try sealed()
        dictionary.remove("CF")

        XCTAssertEqual(openProblem(dictionary), .damaged)
    }

    func test_garbageRecipientsAreNotACrash() throws {
        let dictionary = try sealed()
        let list = try XCTUnwrap(try filterOf(dictionary)["Recipients"] as? PdfArray)
        list.items.insert(PdfString(bytes: [1, 2, 3], isHex: true), at: 0)
        list.items.insert(PdfString(bytes: [], isHex: true), at: 1)
        list.items.insert(PdfNumber(7), at: 2)

        XCTAssertNotNil(try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice))
    }

    func test_onlyGarbageRecipientsIsAWrongCertificate() throws {
        let dictionary = try sealed()
        try filterOf(dictionary)["Recipients"] = PdfArray([PdfString(bytes: [0x30, 0x03, 0x02, 0x01, 0x00], isHex: true)])

        XCTAssertNil(try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice))
    }

    func test_alteredRecipientListGivesNoKeyForTheFileToBeRead() throws {
        // The file key is a digest over every recipient entry, so one added entry changes what the stream data decrypts to.
        let created = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], .aes256)
        let secret = Array("secret".utf8)
        let cipher = created.encryptString(3, 0, secret)
        let dictionary = created.dictionary.copy()
        let list = try XCTUnwrap(try filterOf(dictionary)["Recipients"] as? PdfArray)
        list.items.append(PdfString(bytes: [9], isHex: true))

        let reader = try XCTUnwrap(PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice))

        XCTAssertNotEqual(reader.decryptString(3, 0, cipher), secret)
    }

    func test_manyRecipientsAreReadOnlyToALimit() throws {
        let dictionary = try sealed()
        let list = try XCTUnwrap(try filterOf(dictionary)["Recipients"] as? PdfArray)
        let real = try XCTUnwrap(list.items.first)
        list.items.removeAll()
        for _ in 0..<1500 { list.items.append(PdfString(bytes: [0x30, 0x00], isHex: true)) }
        list.items.append(real)

        XCTAssertNil(try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice))
    }

    func test_aes128FileIsS5WithItsRecipientsInTheFilter() throws {
        let dictionary = try sealed(.aes128)

        XCTAssertEqual((dictionary["SubFilter"] as? PdfName)?.value, "adbe.pkcs7.s5")
        XCTAssertFalse(dictionary.containsKey("Recipients"))
        XCTAssertNotNil(try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice))
    }

    func test_recipientsAtTheTopLevelOpenAnRc4File() throws {
        for (subFilter, v, bits) in [("adbe.pkcs7.s3", 1, 40), ("adbe.pkcs7.s4", 2, 128)] {
            let sealedAes = try PdfSecurity.createPublicKey([PdfRecipient(PublicKeyFiles.alice)], .aes128)
            let stored = try XCTUnwrap(try filterOf(sealedAes.dictionary)["Recipients"] as? PdfArray)
            let dictionary = PdfDictionary()
            dictionary.add("Filter", PdfName("Adobe.PubSec"))
            dictionary.add("SubFilter", PdfName(subFilter))
            dictionary.add("V", PdfNumber(v))
            dictionary.add("Length", PdfNumber(bits))
            dictionary.add("Recipients", stored)

            let reader = try XCTUnwrap(PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice), subFilter)

            XCTAssertTrue(reader.isPublicKey, subFilter)
            let text = Array("secret".utf8)
            XCTAssertEqual(reader.decryptString(4, 0, reader.encryptString(4, 0, text)), text, subFilter)
            XCTAssertEqual(problem { try PdfSecurity.openPublicKey(self.without(dictionary), PublicKeyFiles.alice) }, .damaged, subFilter)
        }
    }

    private func without(_ dictionary: PdfDictionary) -> PdfDictionary {
        let copy = dictionary.copy()
        copy.remove("Recipients")
        return copy
    }

    func test_certificateOfSomeoneElseGivesNull() throws {
        XCTAssertNil(try PdfSecurity.openPublicKey(try sealed(), PublicKeyFiles.eve))
        XCTAssertNil(try PdfSecurity.openPublicKey(try sealed(.aes128), PublicKeyFiles.eve))
    }

    func test_rightCertificateWithoutItsPrivateKeyGivesNull() throws {
        XCTAssertNil(try PdfSecurity.openPublicKey(try sealed(), PublicKeyFiles.publicPart(PublicKeyFiles.alice)))
    }

    func test_damagedRecipientsAreNotACrash() throws {
        var random = SeededRandom(41)
        for strength in PdfCryptStrength.allCases {
            let dictionary = try sealed(strength)
            let list = try XCTUnwrap(try filterOf(dictionary)["Recipients"] as? PdfArray)
            let original = try XCTUnwrap((list.items.first as? PdfString)?.bytes)
            for _ in 0..<60 {
                var damaged = original
                for _ in 0..<(1 + Int(random.next() % 3)) {
                    damaged[Int(random.next() % UInt64(damaged.count))] = UInt8(truncatingIfNeeded: random.next())
                }
                list.items = [PdfString(bytes: damaged, isHex: true)]
                do {
                    _ = try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.alice)
                } catch let error as PdfReadException {
                    XCTAssertEqual(error.problem, .unsupported)
                }
            }
        }
    }

    func test_anEntryOfTheCertificateSealedWithAnUnreadCipherIsUnsupported() throws {
        let dictionary = try sealed()
        let list = try XCTUnwrap(try filterOf(dictionary)["Recipients"] as? PdfArray)
        var entry = try XCTUnwrap((list.items.first as? PdfString)?.bytes)
        let oid = DerWriter.oid(PdfCms.aes256Cbc)
        let at = try XCTUnwrap(entry.indices.first { entry[$0...].starts(with: oid) })
        entry[at + oid.count - 1] = 0x2B
        list.items = [PdfString(bytes: entry, isHex: true)]

        XCTAssertEqual(openProblem(dictionary), .unsupported)
        XCTAssertNil(try PdfSecurity.openPublicKey(dictionary, PublicKeyFiles.eve), "someone else's entry is not an error")
    }
}
#endif
