#if canImport(Security)
import XCTest
import Security
@testable import LazyPDFKit

// No C# twin: what the tests of SignatureMalformedDataTests and PdfSigningTests take from CertificateRequest and
// SignedCms and the kit does not have: Assert.Throws for the two exceptions, a self-signed certificate with the
// extensions the test names, a signature with RSASSA-PSS parameters, and a signer named by its key identifier.

enum SignatureExtraKit {
    /// The message of the InvalidOperationException the expression throws; a failure when it throws another or none.
    static func invalidOperation<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try expression()
        } catch let thrown as InvalidOperationException {
            return thrown.message
        } catch {
            XCTFail("Expected InvalidOperationException, got \(error)", file: file, line: line)
            return ""
        }
        XCTFail("Expected InvalidOperationException, nothing was thrown", file: file, line: line)
        return ""
    }

    static func argumentException<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try expression()
        } catch is ArgumentException {
            return
        } catch {
            return XCTFail("Expected ArgumentException, got \(error)", file: file, line: line)
        }
        XCTFail("Expected ArgumentException, nothing was thrown", file: file, line: line)
    }

    /// An ECDSA signature as r followed by s (IEEE P1363) from its DER sequence, 32 bytes each.
    static func p1363(_ der: [UInt8]) -> [UInt8] {
        var outer = AsnReader(der)
        guard var sequence = try? outer.readSequence(), let r = try? sequence.readInteger(), let s = try? sequence.readInteger() else { return [] }
        func pad(_ value: AsnInteger) -> [UInt8] { [UInt8](repeating: 0, count: max(0, 32 - value.magnitude.count)) + value.magnitude }
        return pad(r) + pad(s)
    }

    /// A certificate under `issuer` with a new RSA key and the extensions given, valid from 2025 to 2040.
    static func issue(_ name: String, under issuer: X509Certificate, _ extensions: [X509Extension]) throws -> X509Certificate {
        let key = try SignatureCrypto.newRsaKey(2048)
        let info = try CertificateBuilder.publicKeyInfo(key)
        let der = try CertificateBuilder.build(subject: X509Certificate.name("CN=\(name), O=Lazy Test"), issuer: issuer.subjectName, publicKeyInfo: info,
                                               notBefore: Pki.notBefore, notAfter: Pki.notAfter, serial: CertificateBuilder.serialNumber(),
                                               extensions: extensions, issuerKey: try XCTUnwrap(issuer.privateKey))
        guard let certificate = X509Certificate(der) else { throw SignatureCryptoException(message: "The certificate does not read.") }
        certificate.privateKey = key
        return certificate
    }

    /// A self-signed certificate valid from 2025 to 2040 with a new RSA key.
    static func selfSigned(subject: [UInt8], extensions: [X509Extension]) throws -> X509Certificate {
        let key = try SignatureCrypto.newRsaKey(2048)
        let info = try CertificateBuilder.publicKeyInfo(key)
        let der = try CertificateBuilder.build(subject: subject, issuer: subject, publicKeyInfo: info, notBefore: Pki.notBefore, notAfter: Pki.notAfter,
                                               serial: CertificateBuilder.serialNumber(), extensions: extensions, issuerKey: key)
        guard let certificate = X509Certificate(der) else { throw SignatureCryptoException(message: "The certificate does not read.") }
        certificate.privateKey = key
        return certificate
    }

    /// A signer for `certificate` named by its subject key identifier, with the certificate and no signed attributes.
    static func signedByKeyIdentifier(_ content: [UInt8], _ certificate: X509Certificate) throws -> [UInt8] {
        let key = try XCTUnwrap(certificate.privateKey)
        let identifier = try XCTUnwrap(try certificate.subjectKeyIdentifier())
        let signature = try SignatureCrypto.sign(key, Sha256.hash(content), .sha256, ec: false)
        let signer = DerWriter.sequence([
            DerWriter.integer(3),
            DerWriter.node(0x80, identifier),
            CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true),
            CmsBuilder.algorithmIdentifier(Oids.rsaEncryption, withNull: true),
            DerWriter.octetString(signature),
        ])
        let data = DerWriter.sequence([
            DerWriter.integer(3),
            DerWriter.set([CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true)]),
            DerWriter.sequence([DerWriter.oid(Oids.data)]),
            DerWriter.setOf([certificate.rawData], tag: 0xA0),
            DerWriter.set([signer]),
        ])
        return DerWriter.sequence([DerWriter.oid(Oids.signedData), DerWriter.context(0, constructed: true, data)])
    }

    /// What SignedCms.ComputeSignature makes with RSASignaturePadding.Pss: the signature algorithm is RSASSA-PSS with a
    /// salt as long as the digest, the parameters written as .NET writes them.
    static func signedWithPss(_ content: [UInt8], _ certificate: X509Certificate, _ digest: HashAlgorithmName) throws -> [UInt8] {
        let pki = Pki.instance
        let digestOid = try Oids.digest(digest)
        let hash = SignatureCrypto.hash(digest, content)
        let attributeList = [
            DerWriter.sequence([DerWriter.oid(Oids.contentType), DerWriter.setOf([DerWriter.oid(Oids.data)])]),
            DerWriter.sequence([DerWriter.oid(Oids.messageDigest), DerWriter.setOf([DerWriter.octetString(hash)])]),
            DerWriter.sequence([DerWriter.oid(Oids.signingTime), DerWriter.setOf([DerWriter.utcTime(Pki.signing)])]),
        ]
        let key = try XCTUnwrap(certificate.privateKey)
        let method: SecKeyAlgorithm
        switch digest {
        case .sha1: method = .rsaSignatureDigestPSSSHA1
        case .sha256: method = .rsaSignatureDigestPSSSHA256
        case .sha384: method = .rsaSignatureDigestPSSSHA384
        case .sha512: method = .rsaSignatureDigestPSSSHA512
        }
        var error: Unmanaged<CFError>?
        guard let made = SecKeyCreateSignature(key, method, Data(SignatureCrypto.hash(digest, DerWriter.setOf(attributeList))) as CFData, &error) else {
            throw SignatureCryptoException(message: "The key could not sign.")
        }
        let parameters = DerWriter.sequence([
            DerWriter.context(0, constructed: true, DerWriter.sequence([DerWriter.oid(digestOid)])),
            DerWriter.context(1, constructed: true, DerWriter.sequence([DerWriter.oid("1.2.840.113549.1.1.8"), DerWriter.sequence([DerWriter.oid(digestOid)])])),
            DerWriter.context(2, constructed: true, DerWriter.integer(hash.count)),
        ])
        let signer = DerWriter.sequence([
            DerWriter.integer(1),
            DerWriter.sequence([certificate.issuerName, DerWriter.integer(certificate.serialNumber)]),
            CmsBuilder.algorithmIdentifier(digestOid, withNull: true),
            DerWriter.setOf(attributeList, tag: 0xA0),
            DerWriter.sequence([DerWriter.oid(Oids.rsaPss), parameters]),
            DerWriter.octetString([UInt8](made as Data)),
        ])
        let data = DerWriter.sequence([
            DerWriter.integer(1),
            DerWriter.set([CmsBuilder.algorithmIdentifier(digestOid, withNull: true)]),
            DerWriter.sequence([DerWriter.oid(Oids.data)]),
            DerWriter.setOf(([certificate] + pki.chain).map { $0.rawData }, tag: 0xA0),
            DerWriter.set([signer]),
        ])
        return DerWriter.sequence([DerWriter.oid(Oids.signedData), DerWriter.context(0, constructed: true, data)])
    }
}
#endif
