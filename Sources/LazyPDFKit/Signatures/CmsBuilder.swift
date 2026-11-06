import Foundation

// Twin of windows/LazyPDF.Core/Signatures/CmsBuilder.cs (the OIDs and the CMS writer): a detached CMS SignedData
// (RFC 5652) written by hand, so that a token behind a delegate can sign the hash we give it. The C# writes with
// AsnWriter in DER; DerWriter (Crypt/Der.swift) and the sorted SET OF in Asn1.swift do the same here. The key of a
// signer is a SecKey, so signing without a delegate is Apple-only.

enum Oids {
    static let data = "1.2.840.113549.1.7.1"
    static let signedData = "1.2.840.113549.1.7.2"
    static let contentType = "1.2.840.113549.1.9.3"
    static let messageDigest = "1.2.840.113549.1.9.4"
    static let signingTime = "1.2.840.113549.1.9.5"
    static let signingCertificateV2 = "1.2.840.113549.1.9.16.2.47"
    static let timestampToken = "1.2.840.113549.1.9.16.2.14"
    static let revocationArchival = "1.2.840.113583.1.1.8"
    static let tstInfo = "1.2.840.113549.1.9.16.1.4"
    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let rsaPss = "1.2.840.113549.1.1.10"
    static let ecPublicKey = "1.2.840.10045.2.1"

    /// Only SHA-256, SHA-384 and SHA-512 sign.
    static func digest(_ name: HashAlgorithmName) throws -> String {
        switch name {
        case .sha256: return "2.16.840.1.101.3.4.2.1"
        case .sha384: return "2.16.840.1.101.3.4.2.2"
        case .sha512: return "2.16.840.1.101.3.4.2.3"
        case .sha1: throw ArgumentException("Only SHA-256, SHA-384 and SHA-512 sign.")
        }
    }

    static func digestName(_ oid: String) -> HashAlgorithmName? {
        switch oid {
        case "1.3.14.3.2.26": return .sha1
        case "2.16.840.1.101.3.4.2.1": return .sha256
        case "2.16.840.1.101.3.4.2.2": return .sha384
        case "2.16.840.1.101.3.4.2.3": return .sha512
        default: return nil
        }
    }

    static func ecdsaWith(_ name: HashAlgorithmName) -> String {
        switch name {
        case .sha256: return "1.2.840.10045.4.3.2"
        case .sha384: return "1.2.840.10045.4.3.3"
        default: return "1.2.840.10045.4.3.4"
        }
    }
}

/// What the CMS needs besides the digest: who signs, with what, and in which flavour.
struct CmsSettings {
    var certificate: X509Certificate
    var chain: [X509Certificate]
    var digest: HashAlgorithmName
    var cades: Bool
    var time: DateTimeOffset
    var external: PdfHashSigner?
}

enum CmsBuilder {
    /// `timestamp` gets the signature value and returns an encoded time stamp token, or nil; added as an unsigned attribute.
    static func build(_ contentDigest: [UInt8], _ s: CmsSettings, _ timestamp: (([UInt8]) throws -> [UInt8]?)?) throws -> [UInt8] {
        let certificate = s.certificate
        let digestOid = try Oids.digest(s.digest)
        var attributes = [
            attribute(Oids.contentType, DerWriter.oid(Oids.data)),
            attribute(Oids.messageDigest, DerWriter.octetString(contentDigest)),
            attribute(Oids.signingCertificateV2, signingCertificate(certificate)),
        ]
        // PAdES leaves the signing time to /M; the older profile has it in the signature.
        if !s.cades { attributes.append(attribute(Oids.signingTime, DerWriter.utcTime(s.time.utc))) }

        let signedAttributes = DerWriter.setOf(attributes)
        let hash = SignatureCrypto.hash(s.digest, signedAttributes)
        let (signature, algorithm) = try sign(hash, s)
        let token = try timestamp?(signature)

        var signer: [[UInt8]] = [
            DerWriter.integer(1),
            DerWriter.sequence([certificate.issuerName, DerWriter.integer(certificate.serialNumber)]),
            algorithmIdentifier(digestOid, withNull: true),
            DerWriter.setOf(attributes, tag: 0xA0),
            algorithm,
            DerWriter.octetString(signature),
        ]
        if let token {
            signer.append(DerWriter.setOf([attribute(Oids.timestampToken, token)], tag: 0xA1))
        }
        let signed = DerWriter.sequence([
            DerWriter.integer(1),
            DerWriter.set([algorithmIdentifier(digestOid, withNull: true)]),
            DerWriter.sequence([DerWriter.oid(Oids.data)]),
            DerWriter.setOf(embedded(s).map { $0.rawData }, tag: 0xA0),
            DerWriter.set([DerWriter.sequence(signer)]),
        ])
        return DerWriter.sequence([DerWriter.oid(Oids.signedData), DerWriter.node(0xA0, signed)])
    }

    private static func embedded(_ s: CmsSettings) -> [X509Certificate] {
        var seen: Set<String> = [s.certificate.thumbprint]
        var result = [s.certificate]
        for c in s.chain where seen.insert(c.thumbprint).inserted { result.append(c) }
        return result
    }

    private static func sign(_ hash: [UInt8], _ s: CmsSettings) throws -> (signature: [UInt8], algorithm: [UInt8]) {
        let certificate = s.certificate
        let ec = certificate.publicKeyAlgorithm == Oids.ecPublicKey
        var derSignature: [UInt8]
        if let external = s.external {
            let raw = try external(hash, s.digest)
            derSignature = ec ? ecdsaDer(raw) : raw
        } else {
            #if canImport(Security)
            guard let key = certificate.privateKey else { throw InvalidOperationException(SignatureText.noPrivateKey) }
            derSignature = try SignatureCrypto.sign(key, hash, s.digest, ec: ec)
            #else
            throw InvalidOperationException(SignatureText.noPrivateKey)
            #endif
        }
        if ec { return (derSignature, algorithmIdentifier(Oids.ecdsaWith(s.digest), withNull: false)) }
        return (derSignature, algorithmIdentifier(Oids.rsaEncryption, withNull: true))
    }

    /// Either half may start with zero bytes, which DER integers do not keep.
    private static func ecdsaDer(_ p1363: [UInt8]) -> [UInt8] {
        let half = p1363.count / 2
        return DerWriter.sequence([DerWriter.integer(unsigned: Array(p1363[0..<half])), DerWriter.integer(unsigned: Array(p1363[half...]))])
    }

    static func algorithmIdentifier(_ oid: String, withNull: Bool) -> [UInt8] {
        DerWriter.sequence(withNull ? [DerWriter.oid(oid), DerWriter.null] : [DerWriter.oid(oid)])
    }

    private static func attribute(_ oid: String, _ value: [UInt8]) -> [UInt8] {
        DerWriter.sequence([DerWriter.oid(oid), DerWriter.setOf([value])])
    }

    /// ESSCertIDv2 (RFC 5035); the hash algorithm is left out when it is SHA-256, its DEFAULT.
    static func signingCertificate(_ certificate: X509Certificate) -> [UInt8] {
        let generalNames = DerWriter.sequence([DerWriter.node(0xA4, certificate.issuerName)])
        let issuerSerial = DerWriter.sequence([generalNames, DerWriter.integer(certificate.serialNumber)])
        let id = DerWriter.sequence([DerWriter.octetString(Sha256.hash(certificate.rawData)), issuerSerial])
        return DerWriter.sequence([DerWriter.sequence([id])])
    }

    static func hashData(_ algorithm: HashAlgorithmName, _ data: [UInt8]) -> [UInt8] {
        SignatureCrypto.hash(algorithm, data)
    }
}
