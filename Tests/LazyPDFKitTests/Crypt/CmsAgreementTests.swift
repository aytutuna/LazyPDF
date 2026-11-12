import XCTest
@testable import LazyPDFKit

// Mirrors the golden and key wrap checks of windows/LazyPDF.Core.Tests/Crypt/PublicKeyEcTests.cs. The C# writes
// the golden envelopes with its own ECDH; here the shared secret is given, so the DER, the KDF and the key wrap
// are checked against the C#'s bytes without the system's key agreement, which Linux has not got.

final class CmsAgreementTests: XCTestCase {
    private let content = (1...24).map { UInt8($0) }
    private let contentKey = (100..<132).map { UInt8($0) }
    private let iv = (200..<216).map { UInt8($0) }

    func test_keyWrapMatchesRfc3394() {
        let kek = Hex.bytes("000102030405060708090A0B0C0D0E0F")
        let key = Hex.bytes("00112233445566778899AABBCCDDEEFF")
        let expected = Hex.bytes("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5")
        XCTAssertEqual(AesKeyWrap.wrap(kek, key), expected)
        XCTAssertEqual(AesKeyWrap.unwrap(kek, expected), key)

        let kek256 = Hex.bytes("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")
        let key256 = Hex.bytes("00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F")
        var wrapped = Hex.bytes("28C9F404C4B810F4CBCCB35CFB87F8263F5786E2D80ED326CBC7F0E71A99F43BFB988B9B7A02DD21")
        XCTAssertEqual(AesKeyWrap.wrap(kek256, key256), wrapped)
        wrapped[3] ^= 1
        XCTAssertNil(AesKeyWrap.unwrap(kek256, wrapped))
    }

    func test_goldenEnvelopesAreWrittenByteForByte() throws {
        for golden in [EcGolden.p256, EcGolden.p384] {
            let identity = try XCTUnwrap(PdfCms.identity(ofCertificate: Hex.bytes(golden.certificate)))

            let written = PdfCms.sealAgreement(content, identity: identity, curve: golden.curve,
                                               ephemeralPoint: Hex.bytes(golden.ephemeralPoint), secret: Hex.bytes(golden.secret),
                                               contentKey: contentKey, iv: iv)

            XCTAssertEqual(written.map(Hex.string), golden.envelope, golden.curve)
        }
    }

    func test_goldenEnvelopesAreRead() throws {
        for golden in [EcGolden.p256, EcGolden.p384] {
            let envelope = try XCTUnwrap(PdfCms.decode(Hex.bytes(golden.envelope)))
            XCTAssertEqual(envelope.agreements.count, 1)
            XCTAssertTrue(envelope.recipients.isEmpty)

            let opened = PdfCms.openAgreement(envelope) { entry in
                entry.curve == golden.curve && entry.point == Hex.bytes(golden.ephemeralPoint) ? Hex.bytes(golden.secret) : nil
            }

            XCTAssertEqual(opened, content, golden.curve)
        }
    }

    func test_wrongSecretOpensNothing() throws {
        let golden = EcGolden.p256
        let envelope = try XCTUnwrap(PdfCms.decode(Hex.bytes(golden.envelope)))
        var secret = Hex.bytes(golden.secret)
        secret[0] ^= 1

        XCTAssertNil(PdfCms.openAgreement(envelope) { _ in secret })
        XCTAssertNil(PdfCms.openAgreement(envelope) { _ in nil })
    }

    func test_envelopeWithoutCurveInOriginatorKeyIsRead() throws {
        for golden in [EcGolden.p256, EcGolden.p384] {
            let identity = try XCTUnwrap(PdfCms.identity(ofCertificate: Hex.bytes(golden.certificate)))
            let written = try XCTUnwrap(PdfCms.sealAgreement(content, identity: identity, curve: golden.curve,
                                                             ephemeralPoint: Hex.bytes(golden.ephemeralPoint), secret: Hex.bytes(golden.secret),
                                                             contentKey: contentKey, iv: iv, writeCurve: false))

            let envelope = try XCTUnwrap(PdfCms.decode(written))
            XCTAssertNil(envelope.agreements.first?.curve, golden.curve)
            let opened = PdfCms.openAgreement(envelope) { _ in Hex.bytes(golden.secret) }

            XCTAssertEqual(opened, content, golden.curve)
        }
    }
}
