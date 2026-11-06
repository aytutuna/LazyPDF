#if canImport(Security)
import Foundation
import Security

// No C# twin: CertificateRequest.Create and CreateSelfSigned of System.Security.Cryptography.X509Certificates write
// a certificate for a key they hold. Security.framework has no certificate writer, so the TBSCertificate is written
// here (RFC 5280) and signed by the issuer's key with RSA and SHA-256. Apple-only, as the keys are.

enum CertificateBuilder {
    /// The SubjectPublicKeyInfo of an RSA or P-256 key.
    static func publicKeyInfo(_ key: SecKey) throws -> [UInt8] {
        let bits = try SignatureCrypto.publicKeyBytes(key)
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        let rsa = (attributes?[kSecAttrKeyType] as? String) == (kSecAttrKeyTypeRSA as String)
        let algorithm = rsa
            ? CmsBuilder.algorithmIdentifier(Oids.rsaEncryption, withNull: true)
            : DerWriter.sequence([DerWriter.oid(Oids.ecPublicKey), DerWriter.oid("1.2.840.10045.3.1.7")])
        return DerWriter.sequence([algorithm, DerWriter.bitString(bits)])
    }

    /// A certificate with the given names and extensions, signed by `issuerKey`.
    static func build(subject: [UInt8], issuer: [UInt8], publicKeyInfo: [UInt8], notBefore: DateTimeOffset, notAfter: DateTimeOffset,
                      serial: [UInt8], extensions: [X509Extension], issuerKey: SecKey) throws -> [UInt8] {
        let algorithm = CmsBuilder.algorithmIdentifier("1.2.840.113549.1.1.11", withNull: true)
        var items = [
            DerWriter.context(0, constructed: true, DerWriter.integer(2)),
            DerWriter.integer(unsigned: serial),
            algorithm,
            issuer,
            DerWriter.sequence([DerWriter.time(notBefore), DerWriter.time(notAfter)]),
            subject,
            publicKeyInfo,
        ]
        if !extensions.isEmpty {
            let encoded = extensions.map { e in
                DerWriter.sequence([DerWriter.oid(e.oid)] + (e.critical ? [DerWriter.boolean(true)] : []) + [DerWriter.octetString(e.value)])
            }
            items.append(DerWriter.context(3, constructed: true, DerWriter.sequence(encoded)))
        }
        let tbs = DerWriter.sequence(items)
        let signature = try SignatureCrypto.sign(issuerKey, Sha256.hash(tbs), .sha256, ec: false)
        return DerWriter.sequence([tbs, algorithm, DerWriter.bitString(signature)])
    }

    static func serialNumber() -> [UInt8] {
        var bytes = SignatureCrypto.randomBytes(8)
        bytes[0] &= 0x7F
        if bytes[0] == 0 { bytes[0] = 1 }
        return bytes
    }

    // MARK: Extensions

    static func basicConstraints(authority: Bool, pathLength: Int? = nil, critical: Bool = true) -> X509Extension {
        var items: [[UInt8]] = []
        if authority { items.append(DerWriter.boolean(true)) }
        if authority, let pathLength { items.append(DerWriter.integer(pathLength)) }
        return X509Extension(oid: "2.5.29.19", critical: critical, value: DerWriter.sequence(items))
    }

    static func keyUsage(_ usage: KeyUsage, critical: Bool = true) -> X509Extension {
        let low = UInt8(usage.rawValue & 0xFF), high = UInt8((usage.rawValue >> 8) & 0xFF)
        let bytes = high == 0 ? [low] : [low, high]
        // A named bit string drops its trailing zero bits.
        var unused: UInt8 = 0
        if let last = bytes.last, last != 0 {
            while (last >> unused) & 1 == 0 { unused += 1 }
        }
        return X509Extension(oid: "2.5.29.15", critical: critical, value: DerWriter.node(0x03, [unused] + bytes))
    }

    static func enhancedKeyUsage(_ purposes: [String], critical: Bool = false) -> X509Extension {
        X509Extension(oid: "2.5.29.37", critical: critical, value: DerWriter.sequence(purposes.map { DerWriter.oid($0) }))
    }

    static func subjectKeyIdentifier(_ publicKeyInfo: [UInt8]) -> X509Extension {
        var reader = AsnReader(publicKeyInfo)
        var bits: [UInt8] = []
        if var spki = try? reader.readSequence(), (try? spki.readSequence()) != nil, let key = try? spki.readBitString() { bits = key }
        return X509Extension(oid: "2.5.29.14", critical: false, value: DerWriter.octetString(Sha1.hash(bits)))
    }

    static func subjectAlternativeEmail(_ email: String) -> X509Extension {
        X509Extension(oid: "2.5.29.17", critical: false, value: DerWriter.sequence([DerWriter.ia5String(email, tag: 0x81)]))
    }
}
#endif
