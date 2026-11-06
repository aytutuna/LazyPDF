#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/TimestampTokenRulesTests.cs: the same cases. What Rfc3161TimestampToken
// accepts as the signer of a time stamp, measured in the C# test and held here: the purposes of the certificate, the
// number of signers and the ESSCertID.

final class TimestampTokenRulesTests: XCTestCase {
    private let pki = Pki.instance
    private let timeStamping = "1.3.6.1.5.5.7.3.8"
    private let emailProtection = "1.3.6.1.5.5.7.3.4"
    private let imprint = Sha256.hash([1, 2, 3])

    private func authority(critical: Bool, _ purposes: [String]) throws -> X509Certificate {
        var extensions = [CertificateBuilder.basicConstraints(authority: false), CertificateBuilder.keyUsage([.digitalSignature])]
        if !purposes.isEmpty { extensions.append(CertificateBuilder.enhancedKeyUsage(purposes, critical: critical)) }
        return try SignatureExtraKit.issue("Authority", under: pki.intermediate, extensions)
    }

    private func info() -> [UInt8] {
        DerWriter.sequence([
            DerWriter.integer(1),
            DerWriter.oid("1.2.3.4.1"),
            DerWriter.sequence([CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true), DerWriter.octetString(imprint)]),
            DerWriter.integer(77),
            DerWriter.generalizedTime(Pki.signing),
        ])
    }

    private func ess(_ certificate: X509Certificate, hashOfOther: Bool, wrongSerial: Bool) -> [UInt8] {
        var serial = certificate.serialNumber.magnitude
        if wrongSerial { serial.append(1) }
        let id = DerWriter.sequence([
            DerWriter.octetString(Sha256.hash(hashOfOther ? pki.leaf.rawData : certificate.rawData)),
            DerWriter.sequence([
                DerWriter.sequence([DerWriter.context(4, constructed: true, certificate.issuerName)]),
                DerWriter.integer(unsigned: serial),
            ]),
        ])
        return DerWriter.sequence([DerWriter.sequence([id])])
    }

    private func token(_ authority: X509Certificate, second: X509Certificate? = nil, hashOfOther: Bool = false, wrongSerial: Bool = false,
                       withoutEss: Bool = false, embedded: Bool = true) throws -> [UInt8] {
        let content = info()
        let signers = try [authority, second].compactMap { $0 }.map { certificate -> [UInt8] in
            var attributes = [
                DerWriter.sequence([DerWriter.oid(Oids.contentType), DerWriter.setOf([DerWriter.oid(Oids.tstInfo)])]),
                DerWriter.sequence([DerWriter.oid(Oids.messageDigest), DerWriter.setOf([DerWriter.octetString(Sha256.hash(content))])]),
            ]
            if !withoutEss {
                attributes.append(DerWriter.sequence([DerWriter.oid(Oids.signingCertificateV2),
                                                      DerWriter.setOf([ess(certificate, hashOfOther: hashOfOther, wrongSerial: wrongSerial)])]))
            }
            let signature = try SignatureCrypto.sign(try XCTUnwrap(certificate.privateKey), Sha256.hash(DerWriter.setOf(attributes)), .sha256, ec: false)
            return DerWriter.sequence([
                DerWriter.integer(1),
                DerWriter.sequence([certificate.issuerName, DerWriter.integer(certificate.serialNumber)]),
                CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true),
                DerWriter.setOf(attributes, tag: 0xA0),
                CmsBuilder.algorithmIdentifier(Oids.rsaEncryption, withNull: true),
                DerWriter.octetString(signature),
            ])
        }
        let certificates = embedded ? [authority] + pki.chain : []
        let data = DerWriter.sequence([
            DerWriter.integer(3),
            DerWriter.set([CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true)]),
            DerWriter.sequence([DerWriter.oid(Oids.tstInfo), DerWriter.context(0, constructed: true, DerWriter.octetString(content))]),
        ] + (embedded ? [DerWriter.setOf(certificates.map { $0.rawData }, tag: 0xA0)] : []) + [DerWriter.set(signers)])
        return DerWriter.sequence([DerWriter.oid(Oids.signedData), DerWriter.context(0, constructed: true, data)])
    }

    private func accepts(_ encoded: [UInt8], _ extra: [X509Certificate] = []) -> Bool {
        guard let (decoded, _) = Rfc3161Token.tryDecode(encoded) else { return false }
        return decoded.verifySignatureForHash(imprint, .sha256, extra) != nil
    }

    func test_theAuthorityHasTheTimeStampingPurposeInOneCriticalExtension() throws {
        let critical = try authority(critical: true, [timeStamping])
        let criticalTwo = try authority(critical: true, [timeStamping, emailProtection])
        let quiet = try authority(critical: false, [timeStamping])
        let quietTwo = try authority(critical: false, [timeStamping, emailProtection])
        let none = try authority(critical: false, [])

        XCTAssertTrue(accepts(try token(critical)))
        XCTAssertTrue(accepts(try token(criticalTwo)))
        XCTAssertFalse(accepts(try token(quiet)))
        XCTAssertFalse(accepts(try token(quietTwo)))
        XCTAssertFalse(accepts(try token(none)))
    }

    func test_anAuthorityThatIsNotInTheTokenIsJudgedTheSameWay() throws {
        let critical = try authority(critical: true, [timeStamping])
        let quiet = try authority(critical: false, [timeStamping])
        let none = try authority(critical: false, [])

        XCTAssertTrue(accepts(try token(critical, embedded: false), [critical]))
        XCTAssertFalse(accepts(try token(critical, embedded: false)))
        XCTAssertFalse(accepts(try token(quiet, embedded: false), [quiet]))
        XCTAssertFalse(accepts(try token(none, embedded: false), [none]))
    }

    func test_aTokenHasOneSignerAndNamesItsCertificateExactly() throws {
        let critical = try authority(critical: true, [timeStamping])
        let other = try authority(critical: true, [timeStamping])

        XCTAssertFalse(accepts(try token(critical, second: other)))
        XCTAssertFalse(accepts(try token(critical, hashOfOther: true)))
        XCTAssertFalse(accepts(try token(critical, wrongSerial: true)))
        XCTAssertFalse(accepts(try token(critical, wrongSerial: true, embedded: false), [critical]))
        XCTAssertFalse(accepts(try token(critical, withoutEss: true)))
    }
}
#endif
