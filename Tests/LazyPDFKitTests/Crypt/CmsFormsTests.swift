import XCTest
@testable import LazyPDFKit

// No C# twin: EnvelopedCms opens these forms and Der.swift and PdfCms.swift stand in for it. BER lengths and
// constructed strings, bytes after the entry, recipients named by key identifier or by an issuer in another string
// type, RSAES-OAEP parameters and the RC2 parameters. Entries from .NET with the same forms are in the golden files.

final class CmsFormsTests: XCTestCase {
    private let iv = (0..<16).map { UInt8(100 + $0) }
    private let key = (0..<32).map { UInt8($0) }
    private let content = Array("a seed and four permission bytes".utf8)

    private func ber(_ tag: UInt8, _ items: [[UInt8]]) -> [UInt8] {
        [tag, 0x80] + items.flatMap { $0 } + [0, 0]
    }

    private var transport: [UInt8] {
        DerWriter.sequence([DerWriter.oid(PdfCms.rsaEncryption), DerWriter.null])
    }

    private func issuerInfo(_ name: String, algorithm: [UInt8]? = nil) -> [UInt8] {
        DerWriter.sequence([
            DerWriter.integer(0),
            DerWriter.sequence([TestCertificate.name(name), DerWriter.node(0x02, TestCertificate.serial(name))]),
            algorithm ?? transport, DerWriter.octetString([9, 9, 9]),
        ])
    }

    private func keyInfo(_ identifier: [UInt8]) -> [UInt8] {
        DerWriter.sequence([DerWriter.integer(2), DerWriter.node(0x80, identifier), transport, DerWriter.octetString([9, 9, 9])])
    }

    private func aes256(_ vector: [UInt8]) -> [UInt8] {
        DerWriter.sequence([DerWriter.oid(PdfCms.aes256Cbc), DerWriter.octetString(vector)])
    }

    private func envelope(_ infos: [[UInt8]], algorithm: [UInt8], encrypted: [UInt8]) -> [UInt8] {
        let inner = DerWriter.sequence([DerWriter.oid(PdfCms.data), algorithm, DerWriter.node(0x80, encrypted)])
        let enveloped = DerWriter.sequence([DerWriter.integer(0), DerWriter.set(infos), inner])
        return DerWriter.sequence([DerWriter.oid(PdfCms.envelopedData), DerWriter.node(0xA0, enveloped)])
    }

    private var encrypted: [UInt8] {
        Aes(key: key).encryptCbc(Aes.padded(content), iv: iv)
    }

    private func certificate(_ name: String, publicKey: [UInt8] = [1, 2, 3, 4], withKeyIdentifier: Bool = true) -> [UInt8] {
        TestCertificate.der(name, publicKey: publicKey, withKeyIdentifier: withKeyIdentifier) { _ in [UInt8](repeating: 7, count: 256) }
    }

    func test_derReaderReadsIndefiniteLengths() throws {
        let reader = DerReader(bytes: [0x30, 0x80, 0x04, 0x01, 0xAA, 0x00, 0x00, 0xFF])

        let root = try XCTUnwrap(reader.root())

        XCTAssertEqual(root.content, 2..<5)
        XCTAssertEqual(root.end, 7)
        XCTAssertEqual(try XCTUnwrap(reader.children(of: root)).count, 1)
    }

    func test_derReaderNestsIndefiniteLengthsToALimit() {
        func nested(_ depth: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            for _ in 0..<depth { bytes = [0x30, 0x80] + bytes + [0, 0] }
            return bytes
        }

        XCTAssertNotNil(DerReader(bytes: nested(10)).root())
        XCTAssertNil(DerReader(bytes: nested(DerReader.maxDepth + 8)).root())
    }

    func test_derReaderJoinsAConstructedOctetString() throws {
        let one = DerWriter.octetString([1, 2]), two = DerWriter.octetString([3])
        let reader = DerReader(bytes: ber(0x24, [one, ber(0x24, [two])]))
        let broken = DerReader(bytes: ber(0x24, [DerWriter.integer(5)]))

        XCTAssertEqual(reader.octets(of: try XCTUnwrap(reader.root())), [1, 2, 3])
        XCTAssertNil(broken.octets(of: try XCTUnwrap(broken.root())))
    }

    func test_anEntryWithEveryLengthIndefiniteAndTheContentInPiecesIsOpened() throws {
        let pieces = ber(0xA0, [DerWriter.octetString(Array(encrypted.prefix(16))), DerWriter.octetString(Array(encrypted.dropFirst(16)))])
        let vector = ber(0x24, [DerWriter.octetString(Array(iv.prefix(8))), DerWriter.octetString(Array(iv.dropFirst(8)))])
        let algorithm = ber(0x30, [DerWriter.oid(PdfCms.aes256Cbc), vector])
        let inner = ber(0x30, [DerWriter.oid(PdfCms.data), algorithm, pieces])
        let enveloped = ber(0x30, [DerWriter.integer(0), ber(0x31, [issuerInfo("A")]), inner])
        let entry = ber(0x30, [DerWriter.oid(PdfCms.envelopedData), ber(0xA0, [enveloped])])

        let found = try XCTUnwrap(PdfCms.decode(entry))

        XCTAssertEqual(found.recipients.count, 1)
        XCTAssertEqual(found.recipients[0].encryptedKey, [9, 9, 9])
        XCTAssertEqual(found.iv, iv)
        XCTAssertEqual(PdfCms.decryptContent(found, key: key), content)
    }

    func test_contentInPiecesThatAreNotOctetStringsIsRefused() {
        let inner = DerWriter.sequence([DerWriter.oid(PdfCms.data), aes256(iv), DerWriter.node(0xA0, DerWriter.integer(1))])
        let enveloped = DerWriter.sequence([DerWriter.integer(0), DerWriter.set([issuerInfo("A")]), inner])
        let entry = DerWriter.sequence([DerWriter.oid(PdfCms.envelopedData), DerWriter.node(0xA0, enveloped)])

        XCTAssertNil(PdfCms.decode(entry))
    }

    func test_bytesAfterTheEntryAreLeftAlone() throws {
        let entry = envelope([issuerInfo("A")], algorithm: aes256(iv), encrypted: encrypted)

        for tail in [[0, 0], [1, 2, 3]] as [[UInt8]] {
            let found = try XCTUnwrap(PdfCms.decode(entry + tail), "\(tail)")
            XCTAssertEqual(PdfCms.decryptContent(found, key: key), content, "\(tail)")
        }
    }

    func test_aRecipientNamedByKeyIdentifierIsReadAndMatched() throws {
        let identity = try XCTUnwrap(PdfCms.identity(ofCertificate: certificate("First")))
        let other = try XCTUnwrap(PdfCms.identity(ofCertificate: certificate("Second", publicKey: [5, 6, 7, 8])))
        let entry = envelope([keyInfo(try XCTUnwrap(identity.keyIdentifier)), issuerInfo("A")], algorithm: aes256(iv), encrypted: encrypted)

        let found = try XCTUnwrap(PdfCms.decode(entry))

        XCTAssertEqual(found.recipients.count, 2)
        XCTAssertEqual(found.recipients[0].keyIdentifier, identity.keyIdentifier)
        XCTAssertNil(found.recipients[0].issuer)
        XCTAssertNil(found.recipients[0].serial)
        XCTAssertEqual(found.recipients[0].encryptedKey, [9, 9, 9])
        XCTAssertNil(found.recipients[1].keyIdentifier)
        XCTAssertTrue(PdfCms.matches(found.recipients[0], identity))
        XCTAssertFalse(PdfCms.matches(found.recipients[0], other))
    }

    func test_aCertificateWithoutTheExtensionIsNamedByAHashOfItsKeyInfo() throws {
        let publicKey: [UInt8] = [10, 20, 30, 40, 50]
        let info = DerWriter.sequence([
            DerWriter.sequence([DerWriter.oid(PdfCms.rsaEncryption), DerWriter.null]),
            DerWriter.node(0x03, [0] + publicKey),
        ])

        let identity = try XCTUnwrap(PdfCms.identity(ofCertificate: certificate("First", publicKey: publicKey, withKeyIdentifier: false)))

        XCTAssertEqual(identity.keyIdentifier, Sha1.hash(info))
        let entry = envelope([keyInfo(Sha1.hash(info))], algorithm: aes256(iv), encrypted: encrypted)
        XCTAssertTrue(PdfCms.matches(try XCTUnwrap(PdfCms.decode(entry)?.recipients.first), identity))
    }

    func test_anIssuerMatchesByTextWhateverItsStringTypeButNotByCase() throws {
        func name(_ tag: UInt8, _ text: [UInt8]) -> [UInt8] {
            DerWriter.sequence([DerWriter.set([DerWriter.sequence([DerWriter.oid("2.5.4.3"), DerWriter.node(tag, text)])])])
        }
        let identity = try XCTUnwrap(PdfCms.identity(ofCertificate: certificate("First")))
        var entry = PdfCmsRecipient(algorithm: PdfCms.rsaEncryption, encryptedKey: [])
        entry.serial = TestCertificate.serial("First")

        entry.issuer = name(0x0C, Array("First".utf8))
        XCTAssertTrue(PdfCms.matches(entry, identity), "UTF8String")
        entry.issuer = name(0x13, Array("First".utf8))
        XCTAssertTrue(PdfCms.matches(entry, identity), "PrintableString")
        entry.issuer = name(0x1E, "First".utf16.flatMap { [UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] })
        XCTAssertTrue(PdfCms.matches(entry, identity), "BMPString")
        entry.issuer = name(0x13, Array("first".utf8))
        XCTAssertFalse(PdfCms.matches(entry, identity), "another case")
        entry.issuer = name(0x13, Array("Second".utf8))
        XCTAssertFalse(PdfCms.matches(entry, identity), "another name")
        entry.issuer = [0x30, 0x00]
        XCTAssertFalse(PdfCms.matches(entry, identity), "no name")
        entry.issuer = [0x13, 0x01, 0x41]
        XCTAssertFalse(PdfCms.matches(entry, identity), "not a name")
    }

    func test_oaepParametersGiveTheHashOrNothing() throws {
        func identifier(_ oid: String) -> [UInt8] {
            DerWriter.sequence([DerWriter.oid(oid), DerWriter.null])
        }
        func parameters(hash: String = PdfCms.sha256, mask: String = PdfCms.sha256, label: [UInt8] = []) -> [UInt8] {
            DerWriter.sequence([
                DerWriter.node(0xA0, identifier(hash)),
                DerWriter.node(0xA1, DerWriter.sequence([DerWriter.oid("1.2.840.113549.1.1.8"), identifier(mask)])),
                DerWriter.node(0xA2, DerWriter.sequence([DerWriter.oid("1.2.840.113549.1.1.9"), DerWriter.octetString(label)])),
            ])
        }
        func read(_ extra: [UInt8]?) throws -> PdfCmsRecipient {
            var parts = [DerWriter.oid(PdfCms.rsaesOaep)]
            if let extra { parts.append(extra) }
            let entry = envelope([issuerInfo("A", algorithm: DerWriter.sequence(parts))], algorithm: aes256(iv), encrypted: encrypted)
            return try XCTUnwrap(PdfCms.decode(entry)?.recipients.first)
        }

        XCTAssertEqual(try read(nil).algorithm, PdfCms.rsaesOaep)
        XCTAssertEqual(try read(nil).oaepHash, PdfCms.sha1, "no parameters")
        XCTAssertEqual(try read(DerWriter.null).oaepHash, PdfCms.sha1, "null parameters")
        XCTAssertEqual(try read(parameters()).oaepHash, PdfCms.sha256)
        XCTAssertEqual(try read(parameters(hash: PdfCms.sha512, mask: PdfCms.sha512)).oaepHash, PdfCms.sha512)
        XCTAssertNil(try read(parameters(mask: PdfCms.sha1)).oaepHash, "a mask hash of its own")
        XCTAssertNil(try read(parameters(label: [1])).oaepHash, "a label")
        XCTAssertNil(try read(DerWriter.sequence([DerWriter.node(0xA3, identifier(PdfCms.sha1))])).oaepHash, "an unknown field")
        XCTAssertNil(try read(DerWriter.octetString([1])).oaepHash, "parameters of another shape")
    }

    func test_rc2ParametersGiveTheEffectiveKeyLengthAndTheIv() throws {
        let vector = Array(iv.prefix(8))
        func read(_ version: [UInt8]) -> PdfEnvelopedData? {
            let algorithm = DerWriter.sequence([DerWriter.oid(PdfCms.rc2Cbc),
                                                DerWriter.sequence([DerWriter.node(0x02, version), DerWriter.octetString(vector)])])
            return PdfCms.decode(envelope([issuerInfo("A")], algorithm: algorithm, encrypted: [UInt8](repeating: 1, count: 16)))
        }

        XCTAssertEqual(read([58])?.rc2Bits, 128)
        XCTAssertEqual(read([0, 160])?.rc2Bits, 40)
        XCTAssertEqual(read([120])?.rc2Bits, 64)
        XCTAssertEqual(read([0x01, 0x00])?.rc2Bits, 256)
        XCTAssertEqual(read([58])?.iv, vector)
        XCTAssertEqual(read([58])?.contentAlgorithm, PdfCms.rc2Cbc)
        XCTAssertNil(read([7]), "a version nobody defined")
        XCTAssertNil(read([]), "no version")
        XCTAssertNil(read([0x80, 0x01]), "a negative version")
    }
}
