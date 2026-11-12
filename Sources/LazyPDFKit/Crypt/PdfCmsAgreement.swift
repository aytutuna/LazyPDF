import Foundation

// Twin of windows/LazyPDF.Core/Crypt/PdfCmsAgreement.cs, without the ECDH step, which needs the system and is left to
// PdfSecurityPublicKey.swift: a KeyAgreeRecipientInfo with ephemeral-static ECDH (RFC 5753), a key encryption key from
// the ANSI X9.63 KDF over the shared secret, and the content key under it by AES key wrap (RFC 3394). Written for
// P-256 and P-384 with AES-256 wrap and the curve's SHA-2 hash; read for P-256, P-384 and P-521, SHA-1 to SHA-512 and
// any AES wrap. Content is AES-CBC. Entries are not matched to the certificate by name: the key wrap's integrity check
// says whether the key was the right one.

/// One RecipientInfo of key agreement type.
struct PdfCmsAgreement {
    /// The object identifier of the originator's curve.
    var curve: String
    /// The originator's ephemeral public key, an uncompressed point.
    var point: [UInt8]
    var userKeyingMaterial: [UInt8]?
    var kdf: String
    var wrap: String
    var encryptedKeys: [[UInt8]]
}

enum AesKeyWrap {
    private static let check = [UInt8](repeating: 0xA6, count: 8)

    static func wrap(_ kek: [UInt8], _ key: [UInt8]) -> [UInt8] {
        let n = key.count / 8
        let aes = Aes(key: kek)
        var a = check
        var r = (0..<n).map { Array(key[8 * $0..<8 * $0 + 8]) }
        for j in 0..<6 {
            for i in 0..<n {
                let b = aes.encryptEcb(a + r[i])
                a = Array(b[0..<8])
                r[i] = Array(b[8..<16])
                xor(&a, UInt64(n * j + i + 1))
            }
        }
        return a + r.flatMap { $0 }
    }

    static func unwrap(_ kek: [UInt8], _ wrapped: [UInt8]) -> [UInt8]? {
        guard wrapped.count >= 24, wrapped.count % 8 == 0 else { return nil }
        let n = wrapped.count / 8 - 1
        let aes = Aes(key: kek)
        var a = Array(wrapped[0..<8])
        var r = (0..<n).map { Array(wrapped[8 * ($0 + 1)..<8 * ($0 + 2)]) }
        for j in stride(from: 5, through: 0, by: -1) {
            for i in stride(from: n - 1, through: 0, by: -1) {
                xor(&a, UInt64(n * j + i + 1))
                let b = aes.decryptEcb(a + r[i])
                a = Array(b[0..<8])
                r[i] = Array(b[8..<16])
            }
        }
        return a == check ? r.flatMap { $0 } : nil
    }

    private static func xor(_ a: inout [UInt8], _ t: UInt64) {
        for k in 0..<8 { a[7 - k] ^= UInt8(truncatingIfNeeded: t >> UInt64(8 * k)) }
    }
}

extension PdfCms {
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let curveP256 = "1.2.840.10045.3.1.7"
    static let curveP384 = "1.3.132.0.34"
    static let curveP521 = "1.3.132.0.35"
    static let aes256Wrap = "2.16.840.1.101.3.4.1.45"

    // Standard and cofactor ECDH are the same on these curves.
    private static let kdfs: [String: ([UInt8]) -> [UInt8]] = [
        "1.3.133.16.840.63.0.2": { Sha1.hash($0) }, "1.3.133.16.840.63.0.3": { Sha1.hash($0) },
        "1.3.132.1.11.1": { Sha256.hash($0) }, "1.3.132.1.14.1": { Sha256.hash($0) },
        "1.3.132.1.11.2": { Sha384.hash($0) }, "1.3.132.1.14.2": { Sha384.hash($0) },
        "1.3.132.1.11.3": { Sha512.hash($0) }, "1.3.132.1.14.3": { Sha512.hash($0) },
    ]
    private static let wraps: [String: Int] = ["2.16.840.1.101.3.4.1.5": 16, "2.16.840.1.101.3.4.1.25": 24, aes256Wrap: 32]
    private static let ciphers: [String: Int] = [aes128Cbc: 16, aes192Cbc: 24, aes256Cbc: 32]

    /// The field size in bytes and the KDF written for the curve; nil for a curve that is not read.
    static func agreementCurve(_ curve: String) -> (size: Int, kdf: String)? {
        switch curve {
        case curveP256: return (32, "1.3.132.1.11.1")
        case curveP384: return (48, "1.3.132.1.11.2")
        case curveP521: return (66, "1.3.132.1.11.3")
        default: return nil
        }
    }

    /// A KeyAgreeRecipientInfo with an originator key (RFC 5652 6.2.2); nil for any other entry or a damaged one.
    static func agreement(_ info: DerNode, _ der: DerReader) -> PdfCmsAgreement? {
        guard info.tag == 0xA1, let parts = der.children(of: info), parts.count >= 4, parts[0].tag == 0x02,
              parts[1].tag == 0xA0, let origin = der.children(of: parts[1]).flatMap({ $0.first }), origin.tag == 0xA1,
              let key = der.children(of: origin), key.count == 2, key[1].tag == 0x03,
              let algorithm = der.children(of: key[0]), algorithm.count == 2,
              der.oid(algorithm[0]) == ecPublicKey, let curve = der.oid(algorithm[1]) else { return nil }
        let bits = der.content(of: key[1])
        guard bits.first == 0 else { return nil }
        var index = 2
        var material: [UInt8]?
        if parts[index].tag == 0xA1 {
            guard let inner = der.children(of: parts[index]).flatMap({ $0.first }), let octets = der.octets(of: inner) else { return nil }
            material = octets
            index += 1
        }
        guard index + 1 < parts.count, parts[index].tag == 0x30, parts[index + 1].tag == 0x30,
              let method = der.children(of: parts[index]), method.count == 2, let kdf = der.oid(method[0]),
              let wrapper = der.children(of: method[1]).flatMap({ $0.first }), let wrap = der.oid(wrapper),
              let entries = der.children(of: parts[index + 1]) else { return nil }
        var keys: [[UInt8]] = []
        for entry in entries {
            guard let pair = der.children(of: entry), pair.count == 2, let wrapped = der.octets(of: pair[1]) else { return nil }
            keys.append(wrapped)
        }
        return PdfCmsAgreement(curve: curve, point: Array(bits.dropFirst()), userKeyingMaterial: material,
                               kdf: kdf, wrap: wrap, encryptedKeys: keys)
    }

    // ANSI X9.63 key derivation: hash of the secret, a 32-bit counter from 1 and the ECC-CMS-SharedInfo of RFC 5753 7.2.
    private static func derivedKey(_ secret: [UInt8], _ hash: ([UInt8]) -> [UInt8], wrap: String, material: [UInt8]?,
                                   length: Int) -> [UInt8] {
        var parts = [DerWriter.sequence([DerWriter.oid(wrap)])]
        if let material { parts.append(DerWriter.node(0xA0, DerWriter.octetString(material))) }
        let bits = UInt32(length * 8)
        parts.append(DerWriter.node(0xA2, DerWriter.octetString([UInt8(bits >> 24), UInt8((bits >> 16) & 0xFF),
                                                                  UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)])))
        let info = DerWriter.sequence(parts)
        var output: [UInt8] = []
        var counter: UInt32 = 1
        while output.count < length {
            output += hash(secret + [UInt8(counter >> 24), UInt8((counter >> 16) & 0xFF), UInt8((counter >> 8) & 0xFF),
                                     UInt8(counter & 0xFF)] + info)
            counter += 1
        }
        return Array(output.prefix(length))
    }

    /// The content of an EnvelopedData that one of its key agreement entries opens; nil when none does. `secret` gives
    /// the ECDH result of the recipient's private key with an entry's ephemeral key, nil when it cannot be made.
    static func openAgreement(_ envelope: PdfEnvelopedData, secret: (PdfCmsAgreement) -> [UInt8]?) -> [UInt8]? {
        guard let keySize = ciphers[envelope.contentAlgorithm] else { return nil }
        for entry in envelope.agreements {
            guard agreementCurve(entry.curve) != nil, let hash = kdfs[entry.kdf], let length = wraps[entry.wrap],
                  let shared = secret(entry) else { continue }
            let kek = derivedKey(shared, hash, wrap: entry.wrap, material: entry.userKeyingMaterial, length: length)
            for wrapped in entry.encryptedKeys {
                if let key = AesKeyWrap.unwrap(kek, wrapped), key.count == keySize,
                   let content = decryptContent(envelope, key: key) { return content }
            }
        }
        return nil
    }

    /// A ContentInfo holding an EnvelopedData of `content` for one certificate: AES-256-CBC under `contentKey`, which is
    /// wrapped under the key derived from `secret`, the ECDH result of `ephemeralPoint`'s key with the certificate's.
    /// Nil for a curve that is not written.
    static func sealAgreement(_ content: [UInt8], identity: PdfCertificateIdentity, curve: String, ephemeralPoint: [UInt8],
                              secret: [UInt8], contentKey: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard let known = agreementCurve(curve), curve != curveP521, let hash = kdfs[known.kdf] else { return nil }
        let kek = derivedKey(secret, hash, wrap: aes256Wrap, material: nil, length: 32)
        let wrapped = AesKeyWrap.wrap(kek, contentKey)
        let encrypted = Aes(key: contentKey).encryptCbc(Aes.padded(content), iv: iv)

        let originator = DerWriter.node(0xA0, DerWriter.node(0xA1,
            DerWriter.sequence([DerWriter.oid(ecPublicKey), DerWriter.oid(curve)]) + DerWriter.node(0x03, [0] + ephemeralPoint)))
        let entry = DerWriter.node(0xA1,
            DerWriter.integer(3) + originator
            + DerWriter.sequence([DerWriter.oid(known.kdf), DerWriter.sequence([DerWriter.oid(aes256Wrap)])])
            + DerWriter.sequence([DerWriter.sequence([
                DerWriter.sequence([identity.issuer, DerWriter.node(0x02, identity.serial)]),
                DerWriter.octetString(wrapped),
            ])]))
        let encryptedContent = DerWriter.sequence([
            DerWriter.oid(data),
            DerWriter.sequence([DerWriter.oid(aes256Cbc), DerWriter.octetString(iv)]),
            DerWriter.node(0x80, encrypted),
        ])
        let enveloped = DerWriter.sequence([DerWriter.integer(2), DerWriter.set([entry]), encryptedContent])
        return DerWriter.sequence([DerWriter.oid(envelopedData), DerWriter.node(0xA0, enveloped)])
    }
}
