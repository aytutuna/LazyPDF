import XCTest
@testable import LazyPDFKit

// No C# twin: the C# makes its certificates with CertificateRequest. An X.509 version 3 certificate, self-signed
// by whoever supplies `sign`, written with the engine's DER writer. It has a subject key identifier and a key
// usage for key and data encipherment, as PublicKeyFiles.cs asks of its certificates.

enum TestCertificate {
    static func name(_ common: String) -> [UInt8] {
        DerWriter.sequence([DerWriter.set([DerWriter.sequence([DerWriter.oid("2.5.4.3"), DerWriter.node(0x0C, Array(common.utf8))])])])
    }

    static func serial(_ common: String) -> [UInt8] {
        var bytes = Array(Sha1.hash(Array(common.utf8)).prefix(8))
        bytes[0] = (bytes[0] & 0x7F) | 0x01
        return bytes
    }

    /// `publicKey` is a PKCS#1 RSAPublicKey; `withKeyIdentifier: false` and `withUsage: false` leave those extensions out; `sign` turns the encoded TBSCertificate into an RSA SHA-256 signature.
    static func der(_ common: String, publicKey: [UInt8], withKeyIdentifier: Bool = true, withUsage: Bool = true, sign: ([UInt8]) -> [UInt8]) -> [UInt8] {
        let algorithm = DerWriter.sequence([DerWriter.oid("1.2.840.113549.1.1.11"), DerWriter.null])
        let subjectKey = DerWriter.sequence([
            DerWriter.sequence([DerWriter.oid(PdfCms.rsaEncryption), DerWriter.null]),
            DerWriter.node(0x03, [0] + publicKey),
        ])
        let validity = DerWriter.sequence([DerWriter.node(0x17, Array("250101000000Z".utf8)),
                                           DerWriter.node(0x17, Array("351231235959Z".utf8))])
        let keyId = DerWriter.octetString(Array(Sha1.hash(publicKey)))
        let identifier = DerWriter.sequence([DerWriter.oid("2.5.29.14"), DerWriter.octetString(keyId)])
        let usage = DerWriter.sequence([DerWriter.oid("2.5.29.15"), [0x01, 0x01, 0xFF],
                                        DerWriter.octetString([0x03, 0x02, 0x04, 0x30])])
        let extensions = DerWriter.node(0xA3, DerWriter.sequence((withKeyIdentifier ? [identifier] : []) + (withUsage ? [usage] : [])))
        let tbs = DerWriter.sequence([
            [0xA0, 0x03, 0x02, 0x01, 0x02], DerWriter.node(0x02, serial(common)), algorithm, name(common), validity,
            name(common), subjectKey, extensions,
        ])
        return DerWriter.sequence([tbs, algorithm, DerWriter.node(0x03, [0] + sign(tbs))])
    }

    /// A certificate for an elliptic curve key, self-signed with ECDSA SHA-256 by whoever supplies `sign`. `publicPoint` is
    /// the uncompressed point and `usage` the encoded key usage bit string (key agreement by default).
    static func derEc(_ common: String, curve: String, publicPoint: [UInt8], usage: [UInt8] = [0x03, 0x02, 0x03, 0x08],
                      sign: ([UInt8]) -> [UInt8]) -> [UInt8] {
        let algorithm = DerWriter.sequence([DerWriter.oid("1.2.840.10045.4.3.2")])
        let subjectKey = DerWriter.sequence([
            DerWriter.sequence([DerWriter.oid(PdfCms.ecPublicKey), DerWriter.oid(curve)]),
            DerWriter.node(0x03, [0] + publicPoint),
        ])
        let validity = DerWriter.sequence([DerWriter.node(0x17, Array("250101000000Z".utf8)),
                                           DerWriter.node(0x17, Array("351231235959Z".utf8))])
        let keyId = DerWriter.sequence([DerWriter.oid("2.5.29.14"), DerWriter.octetString(DerWriter.octetString(Array(Sha1.hash(publicPoint))))])
        let keyUsage = DerWriter.sequence([DerWriter.oid("2.5.29.15"), [0x01, 0x01, 0xFF], DerWriter.octetString(usage)])
        let tbs = DerWriter.sequence([
            [0xA0, 0x03, 0x02, 0x01, 0x02], DerWriter.node(0x02, serial(common)), algorithm, name(common), validity,
            name(common), subjectKey, DerWriter.node(0xA3, DerWriter.sequence([keyId, keyUsage])),
        ])
        return DerWriter.sequence([tbs, algorithm, DerWriter.node(0x03, [0] + sign(tbs))])
    }
}
