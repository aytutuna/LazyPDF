import Foundation

// Twin of windows/LazyPDF.Core/Signatures/Ocsp.cs: the part of an OCSP response (RFC 6960) that matters for a
// signature: who is answering about which certificate, and what they say.

enum RevocationState {
    /// The data says nothing about the certificate.
    case noData
    case good
    case revoked
}

final class OcspResponse {
    private static let sha1 = "1.3.14.3.2.26"
    private static let ocspSigning = "1.3.6.1.5.5.7.3.9"

    private struct Single {
        var hashOid: String
        var nameHash: [UInt8]
        var keyHash: [UInt8]
        var serial: AsnInteger
        var good: Bool
        var revoked: Bool
        var revokedAt: DateTimeOffset?
        var thisUpdate: DateTimeOffset
        var nextUpdate: DateTimeOffset?
    }

    private var responses: [Single] = []
    private var tbs: [UInt8] = []
    private var signatureOid = ""
    private var signature: [UInt8] = []
    private var certificates: [X509Certificate] = []

    private(set) var producedAt = DateTimeOffset(1, 1, 1, 0, 0, 0)
    private(set) var raw: [UInt8] = []

    static func buildRequest(_ certificate: X509Certificate, _ issuer: X509Certificate) -> [UInt8] {
        let id = DerWriter.sequence([
            CmsBuilder.algorithmIdentifier(sha1, withNull: true),
            DerWriter.octetString(Sha1.hash(issuer.subjectName)),
            DerWriter.octetString(Sha1.hash(issuer.encodedKeyValue)),
            DerWriter.integer(certificate.serialNumber),
        ])
        return DerWriter.sequence([DerWriter.sequence([DerWriter.sequence([DerWriter.sequence([id])])])])
    }

    /// Reads an OCSPResponse that carries a BasicOCSPResponse; nil for anything else, including a response that is not "successful".
    static func parse(_ der: [UInt8]) -> OcspResponse? {
        do {
            var outer = AsnReader(der)
            var response = try outer.readSequence()
            if try response.readEnumeratedBytes()[0] != 0 { return nil }
            var wrapper = try response.readSequence(.context(0, constructed: true))
            var bytes = try wrapper.readSequence()
            _ = try bytes.readObjectIdentifier()
            var content = AsnReader(try bytes.readOctetString())
            var basic = try content.readSequence()
            let result = OcspResponse()
            result.tbs = try basic.peekEncodedValue()
            result.raw = der
            var data = try basic.readSequence()
            try result.readData(&data)
            var algorithm = try basic.readSequence()
            result.signatureOid = try algorithm.readObjectIdentifier()
            result.signature = try basic.readBitString()
            if basic.hasData {
                var holder = try basic.readSequence(.context(0, constructed: true))
                var list = try holder.readSequence()
                while list.hasData {
                    if let certificate = X509Certificate(try list.readEncodedValue()) { result.certificates.append(certificate) }
                }
            }
            return result
        } catch {
            return nil
        }
    }

    private func readData(_ data: inout AsnReader) throws {
        if try data.peekTag().hasSameClassAndValue(.context(0)) { _ = try data.readEncodedValue() }
        _ = try data.readEncodedValue() // responderID
        producedAt = try data.readGeneralizedTime()
        var list = try data.readSequence()
        while list.hasData {
            var single = try list.readSequence()
            var id = try single.readSequence()
            var hash = try id.readSequence()
            let hashOid = try hash.readObjectIdentifier()
            let nameHash = try id.readOctetString(), keyHash = try id.readOctetString()
            let serial = try id.readInteger()
            let tag = try single.peekTag()
            let good = tag.value == 0, revoked = tag.value == 1
            var revokedAt: DateTimeOffset?
            if revoked {
                var inner = try single.readSequence(tag)
                revokedAt = try inner.readGeneralizedTime()
            } else {
                _ = try single.readEncodedValue()
            }
            let thisUpdate = try single.readGeneralizedTime()
            var next: DateTimeOffset?
            if single.hasData, try single.peekTag().hasSameClassAndValue(.context(0)) {
                var inner = try single.readSequence(.context(0, constructed: true))
                next = try inner.readGeneralizedTime()
            }
            responses.append(Single(hashOid: hashOid, nameHash: nameHash, keyHash: keyHash, serial: serial, good: good, revoked: revoked,
                                    revokedAt: revokedAt, thisUpdate: thisUpdate, nextUpdate: next))
        }
    }

    /// What the response says of `certificate` if `issuer` or a responder it authorised signed it. With a `time`, "good"
    /// counts only when the response says so for that time (see `covers`).
    func about(_ certificate: X509Certificate, _ issuer: X509Certificate, _ time: DateTimeOffset? = nil)
        -> (state: RevocationState, revokedAt: DateTimeOffset?, thisUpdate: DateTimeOffset) {
        let serial = certificate.serialNumber
        for r in responses {
            guard r.serial == serial, let algorithm = Oids.digestName(r.hashOid) else { continue }
            if CmsBuilder.hashData(algorithm, issuer.subjectName) != r.nameHash || CmsBuilder.hashData(algorithm, issuer.encodedKeyValue) != r.keyHash { continue }
            if !signedBy(issuer) { return (.noData, nil, r.thisUpdate) }
            var state: RevocationState = r.revoked ? .revoked : r.good ? .good : .noData
            // A "good" newer than the response that carries it was not known when the responder signed (RFC 6960 4.2.2.1).
            if state == .good {
                var covered = true
                if let time { covered = Self.covers(r.thisUpdate, r.nextUpdate, time) }
                if r.thisUpdate > producedAt || !covered { state = .noData }
            }
            return (state, r.revokedAt, r.thisUpdate)
        }
        return (.noData, nil, DateTimeOffset(1, 1, 1, 0, 0, 0))
    }

    /// A status holds for `time` when it was issued then or later, or its validity (RFC 6960 2.4, RFC 5280 5.1.2.5) spans it.
    static func covers(_ thisUpdate: DateTimeOffset, _ nextUpdate: DateTimeOffset?, _ time: DateTimeOffset) -> Bool {
        if thisUpdate >= time { return true }
        if let nextUpdate { return nextUpdate >= time }
        return false
    }

    // The issuer itself, or a certificate it issued for answering OCSP (RFC 6960 4.2.2.2) that is in the response.
    private func signedBy(_ issuer: X509Certificate) -> Bool {
        let algorithm = Oids.digestName(Self.digestOf(signatureOid)) ?? .sha256
        if CmsVerifier.verifyRaw(issuer, signatureOid, signature, tbs, algorithm) { return true }
        for candidate in certificates {
            if candidate.issuerName != issuer.subjectName || producedAt < candidate.notBefore || producedAt > candidate.notAfter { continue }
            if !Self.maySignOcsp(candidate) || !CertificateTrust.issuedBy(candidate, issuer, producedAt) { continue }
            if CmsVerifier.verifyRaw(candidate, signatureOid, signature, tbs, algorithm) { return true }
        }
        return false
    }

    // The responder's certificate has to hold when it answered, whatever the clock says now.
    private static func maySignOcsp(_ certificate: X509Certificate) -> Bool {
        guard let purposes = try? certificate.enhancedKeyUsages() else { return false }
        return purposes.contains(ocspSigning)
    }

    /// The digest a signature algorithm OID names, as an OID for `Oids.digestName`.
    static func digestOf(_ signatureOid: String) -> String {
        switch signatureOid {
        case "1.2.840.113549.1.1.5", "1.2.840.10045.4.1": return "1.3.14.3.2.26"
        case "1.2.840.113549.1.1.12", "1.2.840.10045.4.3.3": return "2.16.840.1.101.3.4.2.2"
        case "1.2.840.113549.1.1.13", "1.2.840.10045.4.3.4": return "2.16.840.1.101.3.4.2.3"
        default: return "2.16.840.1.101.3.4.2.1"
        }
    }
}
