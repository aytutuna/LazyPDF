import Foundation
#if canImport(Security)
import Security
#endif

// No C# twin: X509Certificate2 and the parts of X509Certificates the signature code uses. LazyPDFKit reads the
// certificate itself (RFC 5280); only a key operation goes to Security.framework (SignatureCrypto.swift). The private
// key a signer holds is a SecKey, set by whoever loads the identity; without Security a certificate can be read and
// compared but not used to sign or verify.

struct X509Extension {
    var oid: String
    var critical: Bool
    var value: [UInt8]
}

/// The key usage bits with the values of X509KeyUsageFlags.
struct KeyUsage: OptionSet {
    let rawValue: Int
    static let encipherOnly = KeyUsage(rawValue: 1)
    static let crlSign = KeyUsage(rawValue: 2)
    static let keyCertSign = KeyUsage(rawValue: 4)
    static let keyAgreement = KeyUsage(rawValue: 8)
    static let dataEncipherment = KeyUsage(rawValue: 16)
    static let keyEncipherment = KeyUsage(rawValue: 32)
    static let nonRepudiation = KeyUsage(rawValue: 64)
    static let digitalSignature = KeyUsage(rawValue: 128)
    static let decipherOnly = KeyUsage(rawValue: 32768)
}

/// Something that keeps a private key usable and is told before the key is used.
protocol KeyHolder: AnyObject {
    func prepare()
}

public final class X509Certificate {
    public let rawData: [UInt8]
    let tbsCertificate: [UInt8]
    let signatureAlgorithm: String
    let signatureParameters: [UInt8]
    let signatureValue: [UInt8]
    /// The serial number as the unsigned big-endian bytes of the INTEGER.
    let serialNumber: AsnInteger
    let issuerName: [UInt8]
    let subjectName: [UInt8]
    public let notBefore: DateTimeOffset
    public let notAfter: DateTimeOffset
    let publicKeyAlgorithm: String
    let publicKeyParameters: [UInt8]
    let publicKeyInfo: [UInt8]
    /// The contents of the subjectPublicKey BIT STRING.
    let encodedKeyValue: [UInt8]
    let extensions: [X509Extension]

    #if canImport(Security)
    /// The private key of a certificate that signs, set by whoever loaded the identity.
    public var privateKey: SecKey? {
        get {
            keyHolder?.prepare()
            return storedKey
        }
        set { storedKey = newValue }
    }

    private var storedKey: SecKey?

    /// What the private key needs to stay usable, such as the keychain it was imported into.
    var keyHolder: KeyHolder?
    #endif

    /// nil when the bytes are not a certificate this reader understands.
    public init?(_ der: [UInt8]) {
        do {
            var outer = AsnReader(der)
            var certificate = try outer.readSequence()
            let tbsBytes = try certificate.peekEncodedValue()
            var tbs = try certificate.readSequence()
            var algorithm = try certificate.readSequence()
            let signatureOid = try algorithm.readObjectIdentifier()
            let signatureParams = try algorithm.hasData ? algorithm.readEncodedValue() : []
            let signature = try certificate.readBitString()

            if try tbs.peekTag() == .context(0, constructed: true) {
                var version = try tbs.readSequence(.context(0, constructed: true))
                _ = try version.readInteger()
            }
            let serial = try tbs.readInteger()
            _ = try tbs.readSequence()
            let issuer = try tbs.readEncodedValue()
            var validity = try tbs.readSequence()
            let from = try Self.readTime(&validity), to = try Self.readTime(&validity)
            let subject = try tbs.readEncodedValue()
            let keyInfo = try tbs.peekEncodedValue()
            var spki = try tbs.readSequence()
            var keyAlgorithm = try spki.readSequence()
            let keyOid = try keyAlgorithm.readObjectIdentifier()
            let keyParams = try keyAlgorithm.hasData ? keyAlgorithm.readEncodedValue() : []
            let keyBits = try spki.readBitString()

            var found: [X509Extension] = []
            while tbs.hasData {
                let tag = try tbs.peekTag()
                if tag == .context(3, constructed: true) {
                    var wrapper = try tbs.readSequence(tag)
                    var list = try wrapper.readSequence()
                    while list.hasData {
                        var extensionReader = try list.readSequence()
                        let oid = try extensionReader.readObjectIdentifier()
                        var critical = false
                        if try extensionReader.peekTag().value == AsnUniversal.boolean { critical = try extensionReader.readBoolean() }
                        found.append(X509Extension(oid: oid, critical: critical, value: try extensionReader.readOctetString()))
                    }
                } else {
                    _ = try tbs.readEncodedValue()
                }
            }

            rawData = der
            tbsCertificate = tbsBytes
            signatureAlgorithm = signatureOid
            signatureParameters = signatureParams
            signatureValue = signature
            serialNumber = AsnInteger(unsigned: serial.negative ? serial.derContent : serial.magnitude)
            issuerName = issuer
            subjectName = subject
            notBefore = from
            notAfter = to
            publicKeyAlgorithm = keyOid
            publicKeyParameters = keyParams
            publicKeyInfo = keyInfo
            encodedKeyValue = keyBits
            extensions = found
        } catch {
            return nil
        }
    }

    private static func readTime(_ reader: inout AsnReader) throws -> DateTimeOffset {
        try reader.peekTag().value == AsnUniversal.utcTime ? reader.readUtcTime() : reader.readGeneralizedTime()
    }

    /// Whether a certificate's bytes were the same: the C# compares RawData.
    func sameBytes(_ other: X509Certificate) -> Bool { rawData == other.rawData }

    /// SHA-1 of the encoding, as upper-case hex.
    public var thumbprint: String {
        Sha1.hash(rawData).map { String(format: "%02X", $0) }.joined()
    }

    var isSelfIssued: Bool { subjectName == issuerName }

    func extensionNamed(_ oid: String) -> X509Extension? {
        extensions.first { $0.oid == oid }
    }

    // The decoded extensions throw AsnContentException when their value does not decode, as the typed
    // extensions of the C# do when a property is read.

    func keyUsage() throws -> KeyUsage? {
        guard let found = extensionNamed("2.5.29.15") else { return nil }
        var reader = AsnReader(found.value)
        let bits = try reader.readBitString()
        guard !bits.isEmpty else { throw AsnContentException() }
        return KeyUsage(rawValue: Int(bits[0]) | (bits.count > 1 ? Int(bits[1]) << 8 : 0))
    }

    func enhancedKeyUsages() throws -> [String]? {
        guard let found = extensionNamed("2.5.29.37") else { return nil }
        var reader = AsnReader(found.value)
        var list = try reader.readSequence()
        var oids: [String] = []
        while list.hasData { oids.append(try list.readObjectIdentifier()) }
        return oids
    }

    func basicConstraints() throws -> (certificateAuthority: Bool, pathLength: Int?)? {
        guard let found = extensionNamed("2.5.29.19") else { return nil }
        var reader = AsnReader(found.value)
        var sequence = try reader.readSequence()
        var authority = false
        var length: Int?
        if sequence.hasData, try sequence.peekTag().value == AsnUniversal.boolean { authority = try sequence.readBoolean() }
        if sequence.hasData { length = try sequence.readInt() }
        return (authority, length)
    }

    func subjectKeyIdentifier() throws -> [UInt8]? {
        guard let found = extensionNamed("2.5.29.14") else { return nil }
        var reader = AsnReader(found.value)
        return try reader.readOctetString()
    }

    // MARK: Names

    /// The attributes of a DER Name, in the order of the encoding.
    static func attributes(_ name: [UInt8]) -> [(oid: String, value: String)]? {
        do {
            var outer = AsnReader(name)
            var sequence = try outer.readSequence()
            var found: [(String, String)] = []
            while sequence.hasData {
                var set = try sequence.readSetOf()
                while set.hasData {
                    var pair = try set.readSequence()
                    let oid = try pair.readObjectIdentifier()
                    var content = AsnReader(try pair.readEncodedValue())
                    found.append((oid, try Self.text(&content)))
                }
            }
            return found
        } catch {
            return nil
        }
    }

    private static func text(_ reader: inout AsnReader) throws -> String {
        let tag = try reader.peekTag()
        let bytes = try reader.readOctetString(AsnTag(tagClass: tag.tagClass, isConstructed: false, value: tag.value))
        switch tag.value {
        case 30:
            var units: [UInt16] = []
            var i = 0
            while i + 1 < bytes.count {
                units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        case 12:
            return String(decoding: bytes, as: UTF8.self)
        default:
            return Latin1.string(bytes)
        }
    }

    private static let shortNames: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "S", "2.5.4.10": "O", "2.5.4.11": "OU",
        "1.2.840.113549.1.9.1": "E", "2.5.4.5": "SERIALNUMBER", "2.5.4.4": "SN", "2.5.4.42": "G",
    ]

    private static func nameText(_ name: [UInt8]) -> String {
        guard let attributes = attributes(name) else { return "" }
        return attributes.reversed().map { "\(shortNames[$0.oid] ?? $0.oid)=\($0.value)" }.joined(separator: ", ")
    }

    /// The subject as .NET writes it: the most specific attribute first, separated by a comma and a space.
    public var subject: String { Self.nameText(subjectName) }

    public var issuer: String { Self.nameText(issuerName) }

    /// The common name, else the first of the organizational unit, the organization and the e-mail address; empty when there is none.
    public var simpleName: String { Self.simpleName(subjectName) }

    /// The same for the issuer.
    public var issuerSimpleName: String { Self.simpleName(issuerName) }

    private static func simpleName(_ name: [UInt8]) -> String {
        guard let attributes = attributes(name) else { return "" }
        for oid in ["2.5.4.3", "2.5.4.11", "2.5.4.10", "1.2.840.113549.1.9.1"] {
            if let found = attributes.last(where: { $0.oid == oid }), !found.value.isEmpty { return found.value }
        }
        return ""
    }

    /// A DER Name from the text of an X500DistinguishedName ("CN=a, O=b"): the attributes in the order of the
    /// encoding are the reverse of the text. A value may be quoted with doubled quotes.
    static func name(_ text: String) -> [UInt8] {
        var pairs: [(String, String)] = []
        var key = ""
        var value = ""
        var inKey = true
        var quoted = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inKey {
                if c == "=" { inKey = false } else { key.unicodeScalars.append(c) }
            } else if quoted {
                if c == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                        value.unicodeScalars.append(c)
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    value.unicodeScalars.append(c)
                }
            } else if c == "\"" && value.isEmpty {
                quoted = true
            } else if c == "," {
                pairs.append((key.trimmingCharacters(in: .whitespaces), value))
                key = ""
                value = ""
                inKey = true
            } else {
                value.unicodeScalars.append(c)
            }
            i += 1
        }
        if !key.isEmpty { pairs.append((key.trimmingCharacters(in: .whitespaces), value)) }
        let oids = Dictionary(uniqueKeysWithValues: shortNames.map { ($0.value, $0.key) })
        let sets = pairs.reversed().map { pair -> [UInt8] in
            let oid = oids[pair.0.uppercased()] ?? pair.0
            let string = pair.0.uppercased() == "E" ? DerWriter.ia5String(pair.1) : DerWriter.node(0x0C, Array(pair.1.utf8))
            return DerWriter.set([DerWriter.sequence([DerWriter.oid(oid), string])])
        }
        return DerWriter.sequence(sets)
    }
}
