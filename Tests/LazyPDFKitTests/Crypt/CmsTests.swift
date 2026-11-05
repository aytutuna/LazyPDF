import XCTest
@testable import LazyPDFKit

// No C# twin: the C# reads and writes CMS with EnvelopedCms. These check Der.swift and PdfCms.swift, which stand in
// for it, without the system's RSA, so they run on Linux too: the structure round trip, the names of a
// certificate, the cipher and padding rules, and damaged input of every kind.

final class CmsTests: XCTestCase {
    private let iv = (0..<16).map { UInt8(100 + $0) }

    private func certificate(_ name: String, publicKey: [UInt8] = [1, 2, 3, 4]) -> [UInt8] {
        TestCertificate.der(name, publicKey: publicKey) { _ in [UInt8](repeating: 7, count: 256) }
    }

    private func recipient(_ name: String, key: [UInt8] = [9, 9, 9]) -> PdfCmsRecipient {
        PdfCmsRecipient(issuer: TestCertificate.name(name), serial: TestCertificate.serial(name),
                        algorithm: PdfCms.rsaEncryption, encryptedKey: key)
    }

    private func sealed(_ content: [UInt8], key: [UInt8]) -> [UInt8] {
        let encrypted = Aes(key: key).encryptCbc(Aes.padded(content), iv: iv)
        return PdfCms.encode(recipients: [recipient("A"), recipient("B", key: [5])], iv: iv, encryptedContent: encrypted)
    }

    func test_anEnvelopeRoundTripsThroughEncodeAndDecode() throws {
        let encoded = PdfCms.encode(recipients: [recipient("A"), recipient("B", key: [5])], iv: iv,
                                    encryptedContent: [UInt8](repeating: 3, count: 32))

        let envelope = try XCTUnwrap(PdfCms.decode(encoded))

        XCTAssertEqual(envelope.recipients.count, 2)
        XCTAssertEqual(envelope.recipients[0].issuer, TestCertificate.name("A"))
        XCTAssertEqual(envelope.recipients[0].serial, TestCertificate.serial("A"))
        XCTAssertEqual(envelope.recipients[0].algorithm, PdfCms.rsaEncryption)
        XCTAssertEqual(envelope.recipients[0].encryptedKey, [9, 9, 9])
        XCTAssertEqual(envelope.recipients[1].encryptedKey, [5])
        XCTAssertEqual(envelope.contentAlgorithm, PdfCms.aes256Cbc)
        XCTAssertEqual(envelope.iv, iv)
        XCTAssertEqual(envelope.encryptedContent, [UInt8](repeating: 3, count: 32))
        XCTAssertEqual(encoded[0], 0x30)
    }

    func test_aCertificateIsNamedByIssuerSerialAndKeyIdentifier() throws {
        let publicKey: [UInt8] = [10, 20, 30, 40, 50]

        let identity = try XCTUnwrap(PdfCms.identity(ofCertificate: certificate("First", publicKey: publicKey)))

        XCTAssertEqual(identity.issuer, TestCertificate.name("First"))
        XCTAssertEqual(identity.serial, TestCertificate.serial("First"))
        XCTAssertEqual(identity.keyIdentifier, Sha1.hash(publicKey))
    }

    func test_aRecipientMatchesItsCertificateOnly() throws {
        let first = try XCTUnwrap(PdfCms.identity(ofCertificate: certificate("First")))
        let second = try XCTUnwrap(PdfCms.identity(ofCertificate: certificate("Second", publicKey: [5, 6, 7, 8])))
        var padded = recipient("First")
        padded.serial = [0, 0] + TestCertificate.serial("First")
        var byKey = PdfCmsRecipient(algorithm: PdfCms.rsaEncryption, encryptedKey: [])
        byKey.keyIdentifier = first.keyIdentifier

        XCTAssertTrue(PdfCms.matches(recipient("First"), first))
        XCTAssertFalse(PdfCms.matches(recipient("First"), second))
        XCTAssertTrue(PdfCms.matches(padded, first))
        XCTAssertTrue(PdfCms.matches(byKey, first))
        XCTAssertFalse(PdfCms.matches(byKey, second))
    }

    func test_contentIsDecryptedWithTheRightKeyOnly() throws {
        let key = (0..<32).map { UInt8($0) }
        let content = Array("a seed and four permission bytes".utf8)
        let envelope = try XCTUnwrap(PdfCms.decode(sealed(content, key: key)))

        XCTAssertEqual(PdfCms.decryptContent(envelope, key: key), content)
        XCTAssertNil(PdfCms.decryptContent(envelope, key: Array(key.prefix(16))))
        XCTAssertNil(PdfCms.decryptContent(envelope, key: [UInt8](repeating: 1, count: 32)))
    }

    func test_otherContentCiphersAreNotRead() throws {
        let key = (0..<32).map { UInt8($0) }
        var envelope = try XCTUnwrap(PdfCms.decode(sealed([1], key: key)))
        envelope.contentAlgorithm = "1.2.840.113549.3.4"

        XCTAssertNil(PdfCms.decryptContent(envelope, key: key))
    }

    func test_everyTruncationIsRefused() throws {
        let encoded = sealed(Array("content".utf8), key: (0..<32).map { UInt8($0) })

        for length in 0..<encoded.count {
            XCTAssertNil(PdfCms.decode(Array(encoded.prefix(length))), "\(length) bytes")
        }
    }

    func test_damagedEnvelopesAndCertificatesNeverTrap() {
        var random = SeededRandom(21)
        let envelope = sealed(Array("content".utf8), key: (0..<32).map { UInt8($0) })
        let x509 = certificate("First")
        for _ in 0..<3000 {
            for original in [envelope, x509] {
                var damaged = original
                for _ in 0..<(1 + Int(random.next() % 4)) {
                    damaged[Int(random.next() % UInt64(damaged.count))] = UInt8(truncatingIfNeeded: random.next())
                }
                if let found = PdfCms.decode(damaged) {
                    _ = PdfCms.decryptContent(found, key: [UInt8](repeating: 0, count: 32))
                }
                _ = PdfCms.identity(ofCertificate: damaged)
            }
        }
        XCTAssertNil(PdfCms.decode([]))
        XCTAssertNil(PdfCms.identity(ofCertificate: []))
    }

    func test_derReaderRefusesWhatItDoesNotKnow() {
        func node(_ bytes: [UInt8], at position: Int = 0, limit: Int? = nil) -> DerNode? {
            DerReader(bytes: bytes).node(at: position, limit: limit ?? bytes.count)
        }

        XCTAssertNotNil(node([0x04, 0x01, 0xAA]))
        XCTAssertNil(node([0x04, 0x80, 0x00, 0x00]), "indefinite length on a primitive")
        XCTAssertNil(node([0x30, 0x80, 0x04, 0x01, 0xAA]), "indefinite length with no end")
        XCTAssertNil(node([0x30, 0x80, 0x04, 0x01, 0xAA, 0x00]), "end of contents cut short")
        XCTAssertNil(node([0x30, 0x80, 0x04, 0x05, 0xAA, 0x00, 0x00]), "a child past the end")
        XCTAssertNil(node([0x1F, 0x81, 0x00, 0x00]), "high tag number")
        XCTAssertNil(node([0x04, 0x05, 0x01]), "length past the bytes")
        XCTAssertNil(node([0x04, 0x85, 0, 0, 0, 0, 1]), "length of five bytes")
        XCTAssertNil(node([0x04, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]), "length of four gigabytes")
        for position in [Int.max, Int.min, -1, 3, 4] {
            XCTAssertNil(node([0x04, 0x01, 0xAA], at: position), "position \(position)")
        }
        for limit in [Int.max, Int.min, -1, 0, 1, 4] {
            XCTAssertNil(node([0x04, 0x01, 0xAA], limit: limit), "limit \(limit)")
        }
    }

    func test_objectIdentifiersRoundTrip() throws {
        for oid in [PdfCms.envelopedData, PdfCms.data, PdfCms.rsaEncryption, PdfCms.aes256Cbc, "2.5.4.3", "2.5.29.14"] {
            let bytes = DerWriter.oid(oid)
            let reader = DerReader(bytes: bytes)

            XCTAssertEqual(reader.oid(try XCTUnwrap(reader.root())), oid)
        }
        let open = DerReader(bytes: [0x06, 0x02, 0x2A, 0x86])
        XCTAssertNil(open.oid(try XCTUnwrap(open.root())), "an arc that does not end")
        let huge = DerReader(bytes: [0x06, 0x0C] + [UInt8](repeating: 0xFF, count: 11) + [0x7F])
        XCTAssertNil(huge.oid(try XCTUnwrap(huge.root())), "an arc too large to hold")
    }

    func test_lengthsBeyondOneByteAreWrittenAndRead() throws {
        for size in [0, 127, 128, 255, 256, 70000] {
            let bytes = DerWriter.octetString([UInt8](repeating: 1, count: size))
            let reader = DerReader(bytes: bytes)

            XCTAssertEqual(try XCTUnwrap(reader.root()).content.count, size, "\(size)")
        }
    }
}
