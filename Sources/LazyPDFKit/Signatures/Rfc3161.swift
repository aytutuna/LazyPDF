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
        // Rfc3161TimestampToken.TryDecode refuses a token with more than one signer or without the signing certificate
        // attribute, one whose issuerSerial is not the signer's, and one whose embedded signer is no time stamping authority.
        guard cms.signerCount == 1, cms.attributes[Oids.signingCertificateV2]?.count == 1,
              issuerSerialMatches(cms, cms.issuerName, cms.serial) else { return nil }
        if let embedded = cms.findSigner(), !(isAuthority(embedded) && cms.signingCertificateMatches(embedded)) { return nil }
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
              let signer = cms.findSigner(in: cms.certificates + extra), cms.attributes[Oids.signingCertificateV2] != nil,
              Self.isAuthority(signer), cms.signingCertificateMatches(signer),
              Self.issuerSerialMatches(cms, signer.issuerName, signer.serialNumber) else { return nil }
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

    /// The issuerSerial of the ESSCertIDv2, when it has one, names `issuer` and `serial`.
    static func issuerSerialMatches(_ cms: CmsSignature, _ issuer: [UInt8]?, _ serial: AsnInteger) -> Bool {
        guard let values = cms.attributes[Oids.signingCertificateV2], values.count == 1 else { return true }
        do {
            var reader = AsnReader(values[0])
            var outer = try reader.readSequence()
            var ids = try outer.readSequence()
            var id = try ids.readSequence()
            if try id.peekTag().value == AsnUniversal.sequence { _ = try id.readSequence() }
            _ = try id.readOctetString()
            guard id.hasData else { return true }
            var named = try id.readSequence()
            var names = try named.readSequence()
            var directory = try names.readSequence(.context(4, constructed: true))
            let name = try directory.readEncodedValue()
            let number = try named.readInteger()
            return number == serial && (issuer.map { $0 == name } ?? true)
        } catch {
            return false
        }
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
