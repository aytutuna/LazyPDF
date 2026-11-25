import Foundation

// No C# twin: the C# uses EnvelopedCms from System.Security.Cryptography.Pkcs. This is the part of it the
// public-key handler needs (RFC 5652 6): an EnvelopedData of key transport recipients (RSA PKCS#1 v1.5 or
// RSAES-OAEP) and an AES-CBC, 3DES-CBC or RC2-CBC content, read over Der.swift (BER included), and written for
// AES-256 and PKCS#1 v1.5. The RSA step, which needs the system, is left to PdfSecurityPublicKey.swift.
// Key agreement recipients are in PdfCmsAgreement.swift. Not read: key encryption key and password recipients,
// which are skipped like an entry for someone else.

/// One RecipientInfo of key transport type.
struct PdfCmsRecipient {
    /// The whole encoded Name of the certificate's issuer, with the serial number: IssuerAndSerialNumber.
    var issuer: [UInt8]?
    var serial: [UInt8]?
    /// The subject key identifier, when the recipient is named by that instead.
    var keyIdentifier: [UInt8]?
    /// The key encryption algorithm's object identifier.
    var algorithm: String
    var encryptedKey: [UInt8]
    /// For RSAES-OAEP, the object identifier of its hash; nil when the parameters ask for what the system cannot do.
    var oaepHash: String?
}

struct PdfEnvelopedData {
    var recipients: [PdfCmsRecipient]
    /// The content encryption algorithm's object identifier and its IV.
    var contentAlgorithm: String
    var iv: [UInt8]
    var encryptedContent: [UInt8]
    /// For RC2, the effective key length in bits that its parameters give.
    var rc2Bits = 0
    var agreements: [PdfCmsAgreement] = []
}

/// What names a certificate in a RecipientInfo.
struct PdfCertificateIdentity {
    var issuer: [UInt8]
    var serial: [UInt8]
    var keyIdentifier: [UInt8]?
}

enum PdfCms {
    static let envelopedData = "1.2.840.113549.1.7.3"
    static let data = "1.2.840.113549.1.7.1"
    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let rsaesOaep = "1.2.840.113549.1.1.7"
    static let sha1 = "1.3.14.3.2.26"
    static let sha224 = "2.16.840.1.101.3.4.2.4"
    static let sha256 = "2.16.840.1.101.3.4.2.1"
    static let sha384 = "2.16.840.1.101.3.4.2.2"
    static let sha512 = "2.16.840.1.101.3.4.2.3"
    static let aes128Cbc = "2.16.840.1.101.3.4.1.2"
    static let aes192Cbc = "2.16.840.1.101.3.4.1.22"
    static let aes256Cbc = "2.16.840.1.101.3.4.1.42"
    static let tripleDesCbc = "1.2.840.113549.3.7"
    static let rc2Cbc = "1.2.840.113549.3.2"
    static let contentCiphers: Set<String> = [aes128Cbc, aes192Cbc, aes256Cbc, tripleDesCbc, rc2Cbc]
    private static let mgf1 = "1.2.840.113549.1.1.8"
    private static let pSpecified = "1.2.840.113549.1.1.9"
    private static let subjectKeyIdentifier = "2.5.29.14"

    /// The EnvelopedData inside a ContentInfo; nil when it is not one, or damaged.
    static func decode(_ bytes: [UInt8]) -> PdfEnvelopedData? {
        let der = DerReader(bytes: bytes)
        guard let info = der.root(), info.tag == 0x30, let parts = der.children(of: info), parts.count == 2,
              der.oid(parts[0]) == envelopedData, parts[1].tag == 0xA0,
              let wrapper = der.children(of: parts[1]), wrapper.count == 1, wrapper[0].tag == 0x30,
              let fields = der.children(of: wrapper[0]), fields.count >= 3 else { return nil }
        var index = 1
        if fields[index].tag == 0xA0 { index += 1 }
        guard index + 1 < fields.count, fields[index].tag == 0x31, fields[index + 1].tag == 0x30,
              let infos = der.children(of: fields[index]),
              let content = der.children(of: fields[index + 1]), content.count == 3,
              der.oid(content[0]) == data, content[1].tag == 0x30, content[2].tag == 0x80 || content[2].tag == 0xA0,
              let algorithm = der.children(of: content[1]), algorithm.count == 2,
              let contentAlgorithm = der.oid(algorithm[0]),
              let parameters = cipherParameters(contentAlgorithm, algorithm[1], der),
              let encrypted = der.octets(of: content[2]) else { return nil }
        return PdfEnvelopedData(recipients: infos.compactMap { recipient($0, der) }, contentAlgorithm: contentAlgorithm,
                                iv: parameters.iv, encryptedContent: encrypted, rc2Bits: parameters.rc2Bits,
                                agreements: infos.compactMap { agreement($0, der) })
    }

    // An IV as an OCTET STRING; for RC2 (RFC 3370 5.2) a SEQUENCE of the version of its effective key length and the IV.
    private static func cipherParameters(_ oid: String, _ node: DerNode, _ der: DerReader) -> (iv: [UInt8], rc2Bits: Int)? {
        guard oid == rc2Cbc else {
            guard node.tag == 0x04 || node.tag == 0x24, let iv = der.octets(of: node) else { return nil }
            return (iv, 0)
        }
        guard node.tag == 0x30, let fields = der.children(of: node), fields.count == 2, fields[0].tag == 0x02,
              fields[1].tag == 0x04 || fields[1].tag == 0x24, let iv = der.octets(of: fields[1]) else { return nil }
        let version = der.content(of: fields[0])
        guard (1...3).contains(version.count), version[0] & 0x80 == 0 else { return nil }
        switch version.reduce(0, { ($0 << 8) | Int($1) }) {
        case 160: return (iv, 40)
        case 120: return (iv, 64)
        case 58: return (iv, 128)
        case let bits where bits >= 256: return (iv, bits)
        default: return nil
        }
    }

    private static func recipient(_ info: DerNode, _ der: DerReader) -> PdfCmsRecipient? {
        guard info.tag == 0x30, let parts = der.children(of: info), parts.count == 4, parts[0].tag == 0x02,
              let algorithm = der.children(of: parts[2]), let oid = algorithm.first.flatMap({ der.oid($0) }),
              parts[3].tag == 0x04 || parts[3].tag == 0x24, let key = der.octets(of: parts[3]) else { return nil }
        var found = PdfCmsRecipient(algorithm: oid, encryptedKey: key)
        if oid == rsaesOaep { found.oaepHash = oaepHash(algorithm.dropFirst().first, der) }
        if parts[1].tag == 0x30 {
            guard let name = der.children(of: parts[1]), name.count == 2, name[0].tag == 0x30, name[1].tag == 0x02 else {
                return nil
            }
            found.issuer = der.whole(of: name[0])
            found.serial = der.content(of: name[1])
        } else if parts[1].tag == 0x80 || parts[1].tag == 0xA0 {
            guard let identifier = der.octets(of: parts[1]) else { return nil }
            found.keyIdentifier = identifier
        } else {
            return nil
        }
        return found
    }

    // RSAES-OAEP parameters (RFC 4055 4.1): the hash, the mask generation function and the label. Absent they are
    // SHA-1, MGF1 with SHA-1 and no label. The system only does MGF1 with the hash of the padding, and no label.
    private static func oaepHash(_ node: DerNode?, _ der: DerReader) -> String? {
        guard let node else { return sha1 }
        guard node.tag == 0x30, let fields = der.children(of: node) else { return node.tag == 0x05 ? sha1 : nil }
        var hash = sha1, mask = sha1
        for field in fields {
            guard let inner = der.children(of: field)?.first, let parts = der.children(of: inner),
                  let name = parts.first.flatMap({ der.oid($0) }) else { return nil }
            switch field.tag {
            case 0xA0:
                hash = name
            case 0xA1:
                guard name == mgf1, parts.count == 2,
                      let function = der.children(of: parts[1])?.first.flatMap({ der.oid($0) }) else { return nil }
                mask = function
            case 0xA2:
                guard name == pSpecified, parts.count == 2, parts[1].tag == 0x04, parts[1].content.isEmpty else { return nil }
            default:
                return nil
            }
        }
        return hash == mask ? hash : nil
    }

    /// The content, decrypted with the content encryption key; nil for another cipher or a bad key, IV or padding.
    static func decryptContent(_ envelope: PdfEnvelopedData, key: [UInt8]) -> [UInt8]? {
        let cipher = envelope.encryptedContent, iv = envelope.iv
        guard !cipher.isEmpty else { return nil }
        switch envelope.contentAlgorithm {
        case aes128Cbc, aes192Cbc, aes256Cbc:
            let size = envelope.contentAlgorithm == aes128Cbc ? 16 : envelope.contentAlgorithm == aes192Cbc ? 24 : 32
            guard key.count == size, iv.count == 16, cipher.count % 16 == 0 else { return nil }
            return unpadded(Aes(key: key).decryptCbc(cipher, iv: iv), block: 16)
        case tripleDesCbc:
            guard iv.count == 8, cipher.count % 8 == 0, let des = TripleDes(key: key) else { return nil }
            return unpadded(des.decryptCbc(cipher, iv: iv), block: 8)
        case rc2Cbc:
            guard iv.count == 8, cipher.count % 8 == 0, let rc2 = Rc2(key: key, effectiveBits: envelope.rc2Bits) else { return nil }
            return unpadded(rc2.decryptCbc(cipher, iv: iv), block: 8)
        default:
            return nil
        }
    }

    // PKCS#7 padding for a block of 8 or 16, as Aes.unpadded for 16.
    private static func unpadded(_ data: [UInt8], block: Int) -> [UInt8]? {
        guard let last = data.last, last >= 1, Int(last) <= block, Int(last) <= data.count else { return nil }
        for byte in data.suffix(Int(last)) where byte != last { return nil }
        return Array(data.dropLast(Int(last)))
    }

    /// A ContentInfo holding an EnvelopedData with AES-256-CBC content and RSA key transport recipients
    /// named by issuer and serial number, as EnvelopedCms writes it.
    static func encode(recipients: [PdfCmsRecipient], iv: [UInt8], encryptedContent: [UInt8]) -> [UInt8] {
        let infos = recipients.map { recipient in
            DerWriter.sequence([
                DerWriter.integer(0),
                DerWriter.sequence([recipient.issuer ?? [], DerWriter.node(0x02, recipient.serial ?? [])]),
                DerWriter.sequence([DerWriter.oid(rsaEncryption), DerWriter.null]),
                DerWriter.octetString(recipient.encryptedKey),
            ])
        }
        let content = DerWriter.sequence([
            DerWriter.oid(data),
            DerWriter.sequence([DerWriter.oid(aes256Cbc), DerWriter.octetString(iv)]),
            DerWriter.node(0x80, encryptedContent),
        ])
        let enveloped = DerWriter.sequence([DerWriter.integer(0), DerWriter.set(infos), content])
        return DerWriter.sequence([DerWriter.oid(envelopedData), DerWriter.node(0xA0, enveloped)])
    }

    /// The issuer, serial number and subject key identifier of an X.509 certificate. Without the extension the
    /// identifier is the SHA-1 of the encoded SubjectPublicKeyInfo, which is how .NET names the certificate.
    static func identity(ofCertificate bytes: [UInt8]) -> PdfCertificateIdentity? {
        let der = DerReader(bytes: bytes)
        guard let certificate = der.root(), certificate.tag == 0x30, let top = der.children(of: certificate),
              let first = top.first, first.tag == 0x30, let fields = der.children(of: first) else { return nil }
        let offset = fields.first?.tag == 0xA0 ? 1 : 0
        guard fields.count > offset + 3, fields[offset].tag == 0x02, fields[offset + 2].tag == 0x30 else { return nil }
        var identity = PdfCertificateIdentity(issuer: der.whole(of: fields[offset + 2]),
                                              serial: der.content(of: fields[offset]))
        if let extensions = fields.first(where: { $0.tag == 0xA3 }), let list = der.children(of: extensions).flatMap({ $0.first }),
           let each = der.children(of: list) {
            for item in each {
                guard let parts = der.children(of: item), parts.count >= 2, der.oid(parts[0]) == subjectKeyIdentifier,
                      let value = parts.last, let inner = DerReader(bytes: der.content(of: value)).root(),
                      inner.tag == 0x04 else { continue }
                identity.keyIdentifier = Array(der.content(of: value)[inner.content])
            }
        }
        if identity.keyIdentifier == nil, fields.count > offset + 5, fields[offset + 5].tag == 0x30 {
            identity.keyIdentifier = Array(Sha1.hash(der.whole(of: fields[offset + 5])))
        }
        return identity
    }

    /// Whether the entry is addressed to the certificate. Serial numbers compare without leading zero bytes, issuers
    /// by their text whatever its string type, without folding case.
    static func matches(_ recipient: PdfCmsRecipient, _ identity: PdfCertificateIdentity) -> Bool {
        if let issuer = recipient.issuer, let serial = recipient.serial {
            return sameName(issuer, identity.issuer) && trimmed(serial) == trimmed(identity.serial)
        }
        if let keyIdentifier = recipient.keyIdentifier, let own = identity.keyIdentifier { return keyIdentifier == own }
        return false
    }

    private static func trimmed(_ number: [UInt8]) -> [UInt8] {
        Array(number.drop { $0 == 0 })
    }

    private struct NameAttribute: Equatable {
        var oid: String
        var text: [UInt32]
    }

    private static func sameName(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        if left == right { return true }
        guard let one = attributes(left), let other = attributes(right) else { return false }
        return one == other
    }

    private static func attributes(_ name: [UInt8]) -> [[NameAttribute]]? {
        let der = DerReader(bytes: name)
        guard let root = der.root(), root.tag == 0x30, let sets = der.children(of: root) else { return nil }
        var result: [[NameAttribute]] = []
        for set in sets {
            guard set.tag == 0x31, let items = der.children(of: set) else { return nil }
            var group: [NameAttribute] = []
            for item in items {
                guard item.tag == 0x30, let parts = der.children(of: item), parts.count == 2, let oid = der.oid(parts[0]),
                      let text = scalars(parts[1], der) else { return nil }
                group.append(NameAttribute(oid: oid, text: text))
            }
            result.append(group)
        }
        return result
    }

    // The characters of a directory string, so that PrintableString and UTF8String of the same text are equal;
    // any other value is its tag and bytes.
    private static func scalars(_ node: DerNode, _ der: DerReader) -> [UInt32]? {
        let raw = der.content(of: node)
        switch node.tag {
        case 0x0C, 0x13, 0x16:
            guard let text = String(bytes: raw, encoding: .utf8) else { return nil }
            return text.unicodeScalars.map { $0.value }
        case 0x14, 0x1A:
            return raw.map { UInt32($0) }
        case 0x1E:
            guard raw.count % 2 == 0 else { return nil }
            let units = stride(from: 0, to: raw.count, by: 2).map { i in
                raw[i..<i + 2].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
            }
            return String(decoding: units, as: UTF16.self).unicodeScalars.map { $0.value }
        case 0x1C:
            guard raw.count % 4 == 0 else { return nil }
            return stride(from: 0, to: raw.count, by: 4).map { i in
                raw[i..<i + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
        default:
            return [0x1_0000 + UInt32(node.tag)] + raw.map { UInt32($0) }
        }
    }
}
