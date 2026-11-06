import Foundation

// Twin of windows/LazyPDF.Core/Signatures/TimestampClient.cs, with the Rfc3161TimestampRequest and
// Rfc3161TimestampToken of System.Security.Cryptography.Pkcs written out (RFC 3161, RFC 5035): a request, the
// reading of a token and the check of its signature. Posting is the caller's transport, as in the C#.

struct Rfc3161Request {
    var hashOid: String
    var messageHash: [UInt8]
    var nonce: AsnInteger?
    var certificates: Bool

    static func create(hash: [UInt8], _ algorithm: HashAlgorithmName, nonce: [UInt8], certificates: Bool) throws -> Rfc3161Request {
        Rfc3161Request(hashOid: try Oids.digest(algorithm), messageHash: hash, nonce: AsnInteger(unsigned: nonce), certificates: certificates)
    }

    static func create(data: [UInt8], _ algorithm: HashAlgorithmName, nonce: [UInt8], certificates: Bool) throws -> Rfc3161Request {
        try create(hash: SignatureCrypto.hash(algorithm, data), algorithm, nonce: nonce, certificates: certificates)
    }

    func encode() -> [UInt8] {
        var items = [
            DerWriter.integer(1),
            DerWriter.sequence([CmsBuilder.algorithmIdentifier(hashOid, withNull: true), DerWriter.octetString(messageHash)]),
        ]
        if let nonce { items.append(DerWriter.integer(nonce)) }
        if certificates { items.append(DerWriter.boolean(true)) }
        return DerWriter.sequence(items)
    }

    static func tryDecode(_ encoded: [UInt8]) -> Rfc3161Request? {
        do {
            var outer = AsnReader(encoded)
            var request = try outer.readSequence()
            _ = try request.readInteger()
            var imprint = try request.readSequence()
            var algorithm = try imprint.readSequence()
            let oid = try algorithm.readObjectIdentifier()
            let hash = try imprint.readOctetString()
            var nonce: AsnInteger?
            var certificates = false
            while request.hasData {
                let tag = try request.peekTag()
                if tag.tagClass == 0 && tag.value == AsnUniversal.integer {
                    nonce = try request.readInteger()
                } else if tag.tagClass == 0 && tag.value == AsnUniversal.boolean {
                    certificates = try request.readBoolean()
                } else {
                    _ = try request.readEncodedValue()
                }
            }
            return Rfc3161Request(hashOid: oid, messageHash: hash, nonce: nonce, certificates: certificates)
        } catch {
            return nil
        }
    }

    /// The token of a TimeStampResp that grants one for this request; nil when it does not.
    func processResponse(_ response: [UInt8]) -> [UInt8]? {
        do {
            var outer = AsnReader(response)
            var resp = try outer.readSequence()
            var status = try resp.readSequence()
            let code = try status.readInt()
            if code != 0 && code != 1 { return nil }
            let tokenBytes = try resp.readEncodedValue()
            guard let (token, _) = Rfc3161Token.tryDecode(tokenBytes), token.hashOid == hashOid, token.messageHash == messageHash else { return nil }
            if let nonce, token.nonce != nonce { return nil }
            return tokenBytes
        } catch {
            return nil
        }
    }
}

/// An RFC 3161 time stamp token: a CMS SignedData over a TSTInfo.
final class Rfc3161Token {
    let cms: CmsSignature
    let hashOid: String
    let messageHash: [UInt8]
    let timestamp: DateTimeOffset
    let nonce: AsnInteger?

    private init(_ cms: CmsSignature, _ hashOid: String, _ messageHash: [UInt8], _ timestamp: DateTimeOffset, _ nonce: AsnInteger?) {
        self.cms = cms
        self.hashOid = hashOid
        self.messageHash = messageHash
        self.timestamp = timestamp
        self.nonce = nonce
    }

    /// Reads the token at the start of `encoded`; `consumed` is the length of its encoding.
    static func tryDecode(_ encoded: [UInt8]) -> (Rfc3161Token, consumed: Int)? {
        guard let cms = CmsSignature.parse(encoded), cms.contentType == Oids.tstInfo, let content = cms.content else { return nil }
        // Rfc3161TimestampToken.TryDecode refuses a token with more than one signer, or one whose signing certificate
        // attribute (either version) does not name the signer; and one whose embedded signer is no time stamping
        // authority or did not hold at the time of the stamp (checked below, once the time is read).
        guard cms.signerCount == 1 else { return nil }
        let embedded = cms.findSigner()
        guard essAccepts(cms, embedded) else { return nil }
        if let embedded {
            guard isAuthority(embedded), CmsVerifier.check(cms, embedded, { SignatureCrypto.hash($0, content) }) == .ok else { return nil }
        }
        do {
            var outer = AsnReader(content)
            var info = try outer.readSequence()
            _ = try info.readInteger()
            _ = try info.readObjectIdentifier()
            var imprint = try info.readSequence()
            var algorithm = try imprint.readSequence()
            let oid = try algorithm.readObjectIdentifier()
            let hash = try imprint.readOctetString()
            _ = try info.readInteger()
            let time = try info.readGeneralizedTime()
            if let embedded, !holds(embedded, at: time) { return nil }
            var nonce: AsnInteger?
            while info.hasData {
                let tag = try info.peekTag()
                if tag.tagClass == 0 && tag.value == AsnUniversal.integer {
                    nonce = try info.readInteger()
                } else {
                    _ = try info.readEncodedValue()
                }
            }
            return (Rfc3161Token(cms, oid, hash, time, nonce), cms.length)
        } catch {
            return nil
        }
    }

    /// The signer's certificate when `hash` is what the token stamps and its signature holds; `extra` are certificates
    /// the signer may be found among besides those the token carries.
    func verifySignatureForHash(_ hash: [UInt8], _ algorithm: HashAlgorithmName, _ extra: [X509Certificate]) -> X509Certificate? {
        guard Oids.digestName(hashOid) == algorithm, messageHash == hash, let content = cms.content,
              let signer = cms.findSigner(in: cms.certificates + extra), Self.essAccepts(cms, signer),
              Self.isAuthority(signer), Self.holds(signer, at: timestamp) else { return nil }
        let check = CmsVerifier.check(cms, signer) { SignatureCrypto.hash($0, content) }
        return check == .ok ? signer : nil
    }

    /// RFC 3161 2.3: the certificate of the authority has the time stamping purpose in one extended key usage
    /// extension, and the extension is critical.
    static func isAuthority(_ certificate: X509Certificate) -> Bool {
        let extensions = certificate.extensions.filter { $0.oid == "2.5.29.37" }
        guard extensions.count == 1, extensions[0].critical, let purposes = (try? certificate.enhancedKeyUsages()) ?? nil else { return false }
        return purposes.contains("1.3.6.1.5.5.7.3.8")
    }

    static func holds(_ certificate: X509Certificate, at time: DateTimeOffset) -> Bool {
        certificate.notBefore <= time && time <= certificate.notAfter
    }

    private static let signingCertificateV1 = "1.2.840.113549.1.9.16.2.12"

    /// The signing certificate attribute, in the version of RFC 2634 (SHA-1) or of RFC 5035 or both, names the signer: the
    /// hash is that of its certificate, and an issuerSerial, one directoryName and a serial, is its issuer and serial.
    /// Without the certificate (an SKI signer that is not in the token) the issuerSerial can only be held against the
    /// signer identifier, when that is an issuer and serial.
    static func essAccepts(_ cms: CmsSignature, _ signer: X509Certificate?) -> Bool {
        let versions: [(values: [[UInt8]]?, version2: Bool)] = [(cms.attributes[signingCertificateV1], false), (cms.attributes[Oids.signingCertificateV2], true)]
        guard versions.contains(where: { $0.values != nil }) else { return false }
        for (values, version2) in versions {
            guard let values else { continue }
            guard values.count == 1, let id = certificateId(values[0], version2) else { return false }
            if let signer {
                guard CmsBuilder.hashData(id.algorithm, signer.rawData) == id.hash else { return false }
                if let (issuer, serial) = id.issuerSerial, issuer != signer.issuerName || serial != signer.serialNumber { return false }
            } else if let (issuer, serial) = id.issuerSerial, let name = cms.issuerName, issuer != name || serial != cms.serial {
                return false
            }
        }
        return true
    }

    private static func certificateId(_ value: [UInt8], _ version2: Bool) -> (algorithm: HashAlgorithmName, hash: [UInt8], issuerSerial: ([UInt8], AsnInteger)?)? {
        do {
            var reader = AsnReader(value)
            var outer = try reader.readSequence()
            guard !reader.hasData else { return nil }
            var ids = try outer.readSequence()
            // Every id has to decode, as SigningCertificate(V2)Asn.Decode makes it; the first is the one that names the signer.
            var first: (oid: String, hash: [UInt8], issuerSerial: ([UInt8], AsnInteger)?)?
            while ids.hasData {
                var id = try ids.readSequence()
                let parsed = try readId(&id, version2)
                if first == nil { first = parsed }
            }
            // The policies, when there are any, are one sequence.
            if outer.hasData {
                _ = try outer.readSequence()
                guard !outer.hasData else { return nil }
            }
            guard let first, let algorithm = Oids.digestName(first.oid) else { return nil }
            return (algorithm, first.hash, first.issuerSerial)
        } catch {
            return nil
        }
    }

    private static func readId(_ id: inout AsnReader, _ version2: Bool) throws -> (oid: String, hash: [UInt8], issuerSerial: ([UInt8], AsnInteger)?) {
        var oid = version2 ? "2.16.840.1.101.3.4.2.1" : "1.3.14.3.2.26"
        if version2, try id.peekTag().value == AsnUniversal.sequence {
            var named = try id.readSequence()
            oid = try named.readObjectIdentifier()
        }
        let hash = try id.readOctetString()
        guard id.hasData else { return (oid, hash, nil) }
        var named = try id.readSequence()
        var names = try named.readSequence()
        var directory = try names.readSequence(.context(4, constructed: true))
        let issuer = try directory.readEncodedValue()
        guard !directory.hasData, !names.hasData else { throw AsnContentException() }
        let serial = try named.readInteger()
        guard !named.hasData, !id.hasData else { throw AsnContentException() }
        return (oid, hash, (issuer, serial))
    }

    /// The certificate the token names as its signer, among the ones it carries.
    var signerCertificate: X509Certificate? { cms.findSigner() }
}

enum TimestampClient {
    /// Asks the server for an RFC 3161 token over `value` (or over itself when it already is the hash) and returns the
    /// token encoded. The token's own signature is checked when a file is verified, not here.
    static func request(_ settings: TimestampSettings, _ url: String, _ value: [UInt8], hashed: Bool = false) throws -> [UInt8] {
        var nonce = SignatureCrypto.randomBytes(8)
        nonce[0] &= 0x7F
        let request = try hashed
            ? Rfc3161Request.create(hash: value, settings.digest, nonce: nonce, certificates: true)
            : Rfc3161Request.create(data: value, settings.digest, nonce: nonce, certificates: true)
        guard let response = settings.transport.post(url, "application/timestamp-query", request.encode()) else {
            throw InvalidOperationException(SignatureText.noTimestamp)
        }
        guard let token = request.processResponse(response) else { throw InvalidOperationException(SignatureText.noTimestamp) }
        return token
    }
}
