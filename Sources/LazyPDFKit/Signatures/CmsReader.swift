import Foundation

// Twin of windows/LazyPDF.Core/Signatures/CmsReader.cs: the first signer of a CMS SignedData, as far as verifying
// needs it, and the check of its digest and signature. The C# reads with AsnReader; AsnReader in Asn1.swift throws
// the same AsnContentException for what does not read.

final class CmsSignature {
    private(set) var length = 0
    private(set) var signerCount = 0
    private(set) var certificates: [X509Certificate] = []
    private(set) var digestOid = ""
    private(set) var signedAttributes: [UInt8]?
    var attributes: [String: [[UInt8]]] = [:]
    private(set) var unsignedAttributes: [String: [[UInt8]]] = [:]
    private(set) var signatureOid = ""
    private(set) var signatureParameters: [UInt8] = []
    private(set) var signature: [UInt8] = []
    private(set) var issuerName: [UInt8]?
    private(set) var serial = AsnInteger(0)
    private(set) var keyId: [UInt8]?
    private(set) var content: [UInt8]?
    private(set) var contentType = ""

    /// Reads the ContentInfo at the start of `data`; nil when it is not a SignedData with a signer.
    static func parse(_ data: [UInt8]) -> CmsSignature? {
        do {
            var reader = AsnReader(data)
            let length = try reader.peekEncodedValue().count
            var info = try reader.readSequence()
            if try info.readObjectIdentifier() != Oids.signedData { return nil }
            var wrapper = try info.readSequence(.context(0, constructed: true))
            var signed = try wrapper.readSequence()
            let result = CmsSignature()
            result.length = length
            _ = try signed.readInteger()
            _ = try signed.readSetOf()
            var encapsulated = try signed.readSequence()
            result.contentType = try encapsulated.readObjectIdentifier()
            if encapsulated.hasData {
                var inner = try encapsulated.readSequence(.context(0, constructed: true))
                result.content = try inner.readOctetString()
            }
            if signed.hasData, try signed.peekTag().hasSameClassAndValue(.context(0)) {
                var certificates = try signed.readSetOf(.context(0, constructed: true))
                while certificates.hasData {
                    let encoded = try certificates.readEncodedValue()
                    if encoded[0] != 0x30 { continue }
                    if let certificate = X509Certificate(encoded) { result.certificates.append(certificate) }
                }
            }
            if signed.hasData, try signed.peekTag().hasSameClassAndValue(.context(1)) { _ = try signed.readEncodedValue() }
            var signers = try signed.readSetOf()
            if !signers.hasData { return nil }
            var signer = try signers.readSequence()
            try result.readSigner(&signer)
            result.signerCount = 1
            // Bytes after the first signer that are no signer are not counted: CmsSignature.Parse reads the first one only.
            while signers.hasData, (try? signers.readEncodedValue()) != nil { result.signerCount += 1 }
            return result
        } catch {
            return nil
        }
    }

    private func readSigner(_ signer: inout AsnReader) throws {
        _ = try signer.readInteger()
        if try signer.peekTag().hasSameClassAndValue(.context(0)) {
            keyId = try signer.readOctetString(.context(0))
        } else {
            var id = try signer.readSequence()
            issuerName = try id.readEncodedValue()
            serial = try id.readInteger()
        }
        var digest = try signer.readSequence()
        digestOid = try digest.readObjectIdentifier()
        if try signer.peekTag().hasSameClassAndValue(.context(0)) {
            // Signed over the DER of the set, with the universal tag instead of the implicit one.
            var encoded = try signer.peekEncodedValue()
            encoded[0] = 0x31
            signedAttributes = encoded
            var set = try signer.readSetOf(.context(0, constructed: true))
            attributes = try Self.readAttributes(&set)
        }
        var algorithm = try signer.readSequence()
        signatureOid = try algorithm.readObjectIdentifier()
        signatureParameters = try algorithm.hasData ? algorithm.readEncodedValue() : []
        signature = try signer.readOctetString()
        if signer.hasData, try signer.peekTag().hasSameClassAndValue(.context(1)) {
            var set = try signer.readSetOf(.context(1, constructed: true))
            unsignedAttributes = try Self.readAttributes(&set)
        }
    }

    private static func readAttributes(_ set: inout AsnReader) throws -> [String: [[UInt8]]] {
        var into: [String: [[UInt8]]] = [:]
        while set.hasData {
            var attribute = try set.readSequence()
            let oid = try attribute.readObjectIdentifier()
            var values = try attribute.readSetOf()
            var list = into[oid] ?? []
            while values.hasData { list.append(try values.readEncodedValue()) }
            into[oid] = list
        }
        return into
    }

    /// The signer's certificate among the embedded ones, nil when it is not in the signature.
    func findSigner() -> X509Certificate? {
        findSigner(in: certificates)
    }

    /// The signer's certificate among `pool`.
    func findSigner(in pool: [X509Certificate]) -> X509Certificate? {
        for c in pool {
            if let issuerName {
                if c.issuerName == issuerName && c.serialNumber == serial { return c }
            } else if let keyId, let id = try? c.subjectKeyIdentifier(), id == keyId {
                return c
            }
        }
        return nil
    }

    /// The signing-certificate-v2 attribute (RFC 5035), when there is one, names the signer's certificate by hash;
    /// false when it names another, which would let a signature be moved to a different certificate.
    func signingCertificateMatches(_ signer: X509Certificate) -> Bool {
        guard let values = attributes[Oids.signingCertificateV2], values.count == 1 else { return true }
        do {
            var reader = AsnReader(values[0])
            var outer = try reader.readSequence()
            var ids = try outer.readSequence()
            var id = try ids.readSequence()
            var algorithm = HashAlgorithmName.sha256
            if try id.peekTag().value == AsnUniversal.sequence {
                var named = try id.readSequence()
                algorithm = Oids.digestName(try named.readObjectIdentifier()) ?? .sha256
            }
            let expected = try id.readOctetString()
            return CmsBuilder.hashData(algorithm, signer.rawData) == expected
        } catch {
            return false
        }
    }

    /// The content digest the signer's attributes name; nil without one.
    func messageDigest() -> [UInt8]? {
        guard let values = attributes[Oids.messageDigest], values.count == 1 else { return nil }
        var reader = AsnReader(values[0])
        return try? reader.readOctetString()
    }

    func signingTime() -> DateTimeOffset? {
        guard let values = attributes[Oids.signingTime], values.count == 1 else { return nil }
        do {
            var reader = AsnReader(values[0])
            return try reader.peekTag().value == AsnUniversal.utcTime ? reader.readUtcTime() : reader.readGeneralizedTime()
        } catch {
            return nil
        }
    }
}

enum CmsCheck {
    case ok
    case digestMismatch
    case badSignature
    case unsupported
}

enum CmsVerifier {
    /// A comparison that takes as long whatever the bytes are, as CryptographicOperations.FixedTimeEquals.
    static func fixedTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    /// Checks the message digest against `contentDigest` (made with the signer's own digest algorithm) and the signature with the certificate's key.
    static func check(_ cms: CmsSignature, _ signer: X509Certificate, _ contentDigest: (HashAlgorithmName) -> [UInt8]) -> CmsCheck {
        guard let algorithm = Oids.digestName(cms.digestOid) else { return .unsupported }
        // Without signed attributes the signature is over the content's digest itself (RFC 5652 5.4).
        let hash: [UInt8]
        if let attributes = cms.signedAttributes {
            guard let expected = cms.messageDigest(), fixedTimeEquals(expected, contentDigest(algorithm)) else { return .digestMismatch }
            hash = CmsBuilder.hashData(algorithm, attributes)
        } else {
            hash = contentDigest(algorithm)
        }
        let oid = cms.signatureOid
        if oid == Oids.rsaPss { return verifyPss(cms, signer, hash, algorithm) }
        if oid.hasPrefix("1.2.840.113549.1.1.") { return verifyRsa(signer, hash, algorithm, cms.signature, pss: false) }
        if oid.hasPrefix("1.2.840.10045.4.") { return verifyEcdsa(signer, hash, cms.signature) }
        return .unsupported
    }

    static func verifyRaw(_ issuer: X509Certificate, _ signatureOid: String, _ signature: [UInt8], _ signed: [UInt8], _ algorithm: HashAlgorithmName) -> Bool {
        let hash = CmsBuilder.hashData(algorithm, signed)
        return signatureOid.hasPrefix("1.2.840.10045.4.")
            ? verifyEcdsa(issuer, hash, signature) == .ok
            : verifyRsa(issuer, hash, algorithm, signature, pss: false) == .ok
    }

    private static func verifyRsa(_ signer: X509Certificate, _ hash: [UInt8], _ algorithm: HashAlgorithmName, _ signature: [UInt8], pss: Bool) -> CmsCheck {
        SignatureCrypto.verifyRsa(signer, hash, algorithm, signature, pss: pss) == true ? .ok : .badSignature
    }

    private static func verifyEcdsa(_ signer: X509Certificate, _ hash: [UInt8], _ signature: [UInt8]) -> CmsCheck {
        SignatureCrypto.verifyEcdsa(signer, hash, signature) == true ? .ok : .badSignature
    }

    // RSASSA-PSS-params (RFC 4055): .NET takes a salt as long as the digest, which is what PDF signers use.
    private static func verifyPss(_ cms: CmsSignature, _ signer: X509Certificate, _ hash: [UInt8], _ algorithm: HashAlgorithmName) -> CmsCheck {
        var saltLength = 20
        if !cms.signatureParameters.isEmpty {
            do {
                var reader = AsnReader(cms.signatureParameters)
                var parameters = try reader.readSequence()
                while parameters.hasData {
                    let tag = try parameters.peekTag()
                    var field = try parameters.readSequence(tag)
                    if tag.value == 2 { saltLength = try field.readInt() }
                }
            } catch {
                return .badSignature
            }
        }
        if saltLength != hash.count { return .unsupported }
        return verifyRsa(signer, hash, algorithm, cms.signature, pss: true)
    }
}
