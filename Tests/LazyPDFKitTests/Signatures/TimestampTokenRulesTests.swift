#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/TimestampTokenRulesTests.cs: the same cases. What Rfc3161TimestampToken
// accepts as the signer of a time stamp, measured in the C# test and held here: the purposes of the certificate, the
// time it holds, the number of signers, and the signing certificate attribute in both its versions.

final class TimestampTokenRulesTests: XCTestCase {
    private let pki = Pki.instance
    private let timeStamping = "1.3.6.1.5.5.7.3.8"
    private let emailProtection = "1.3.6.1.5.5.7.3.4"
    private let imprint = Sha256.hash([1, 2, 3])

    private func authority(critical: Bool, _ purposes: [String], from: DateTimeOffset = Pki.notBefore, until: DateTimeOffset = Pki.notAfter) throws -> X509Certificate {
        var extensions = [CertificateBuilder.basicConstraints(authority: false), CertificateBuilder.keyUsage([.digitalSignature])]
        if !purposes.isEmpty { extensions.append(CertificateBuilder.enhancedKeyUsage(purposes, critical: critical)) }
        return try SignatureExtraKit.issue("Authority", under: pki.intermediate, extensions, from: from, until: until)
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

    private enum EssShape { case plain, unknownHash, trailingId, trailingSerial, trailingName, secondMalformed, secondOther, policiesNull, policiesTwo, policiesEmpty, policiesGood }

    private func ess(_ certificate: X509Certificate, hashOfOther: Bool, wrongSerial: Bool, twoNames: Bool, shape: EssShape) -> [UInt8] {
        var serial = certificate.serialNumber.magnitude
        if wrongSerial { serial.append(1) }
        let null = DerWriter.null
        var name = [DerWriter.context(4, constructed: true, certificate.issuerName)]
        if shape == .trailingName { name = [DerWriter.context(4, constructed: true, certificate.issuerName + null)] }
        var names = name
        if twoNames { names.append(DerWriter.ia5String("x.example", tag: 0x82)) }
        var issuerSerial = [DerWriter.sequence(names), DerWriter.integer(unsigned: serial)]
        if shape == .trailingSerial { issuerSerial.append(null) }
        var parts: [[UInt8]] = []
        if shape == .unknownHash { parts.append(DerWriter.sequence([DerWriter.oid("1.2.3.4")])) }
        parts.append(DerWriter.octetString(Sha256.hash(hashOfOther ? pki.leaf.rawData : certificate.rawData)))
        parts.append(DerWriter.sequence(issuerSerial))
        if shape == .trailingId { parts.append(null) }
        var ids = [DerWriter.sequence(parts)]
        if shape == .secondMalformed { ids.append(null) }
        if shape == .secondOther { ids.append(DerWriter.sequence([DerWriter.octetString(Sha256.hash(pki.leaf.rawData))])) }
        var all = [DerWriter.sequence(ids)]
        switch shape {
        case .policiesNull: all.append(null)
        case .policiesTwo: all += [DerWriter.sequence([]), DerWriter.sequence([])]
        case .policiesEmpty: all.append(DerWriter.sequence([]))
        case .policiesGood: all.append(DerWriter.sequence([DerWriter.sequence([DerWriter.oid("2.5.29.32.0")])]))
        default: break
        }
        return DerWriter.sequence(all)
    }

    /// The SigningCertificate attribute of RFC 2634, with a SHA-1 hash.
    private func essVersion1(_ certificate: X509Certificate, hashOfOther: Bool) -> [UInt8] {
        DerWriter.sequence([DerWriter.sequence([DerWriter.sequence([DerWriter.octetString(Sha1.hash(hashOfOther ? pki.leaf.rawData : certificate.rawData))])])])
    }

    private struct Shape {
        var second: X509Certificate?
        var hashOfOther = false
        var wrongSerial = false
        var withoutEss = false
        var embedded = true
        var twoNames = false
        var version1 = false
        var version1Other = false
        var version2 = true
        var keyIdentifier = false
        var version2Other = false
        var strayByte = false
        var essShape = EssShape.plain
        var spoiled = false
    }

    private func token(_ authority: X509Certificate, _ shape: Shape = Shape()) throws -> [UInt8] {
        let content = info()
        let signers = try [authority, shape.second].compactMap { $0 }.map { certificate -> [UInt8] in
            var attributes = [
                DerWriter.sequence([DerWriter.oid(Oids.contentType), DerWriter.setOf([DerWriter.oid(Oids.tstInfo)])]),
                DerWriter.sequence([DerWriter.oid(Oids.messageDigest), DerWriter.setOf([DerWriter.octetString(Sha256.hash(content))])]),
            ]
            if !shape.withoutEss && shape.version2 {
                let value = ess(certificate, hashOfOther: shape.hashOfOther || shape.version2Other, wrongSerial: shape.wrongSerial, twoNames: shape.twoNames, shape: shape.essShape)
                attributes.append(DerWriter.sequence([DerWriter.oid(Oids.signingCertificateV2), DerWriter.setOf([value])]))
            }
            if shape.version1 {
                attributes.append(DerWriter.sequence([DerWriter.oid("1.2.840.113549.1.9.16.2.12"),
                                                      DerWriter.setOf([essVersion1(certificate, hashOfOther: shape.version1Other)])]))
            }
            let signature = try SignatureCrypto.sign(try XCTUnwrap(certificate.privateKey), Sha256.hash(DerWriter.setOf(attributes)), .sha256, ec: false)
            let identifier = shape.keyIdentifier
                ? DerWriter.node(0x80, try XCTUnwrap(try certificate.subjectKeyIdentifier()))
                : DerWriter.sequence([certificate.issuerName, DerWriter.integer(certificate.serialNumber)])
            return DerWriter.sequence([
                DerWriter.integer(shape.keyIdentifier ? 3 : 1),
                identifier,
                CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true),
                DerWriter.setOf(attributes, tag: 0xA0),
                CmsBuilder.algorithmIdentifier(Oids.rsaEncryption, withNull: true),
                DerWriter.octetString(signature),
            ])
        }
        let certificates = shape.embedded ? [authority] + pki.chain : []
        let data = DerWriter.sequence([
            DerWriter.integer(3),
            DerWriter.set([CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true)]),
            DerWriter.sequence([DerWriter.oid(Oids.tstInfo), DerWriter.context(0, constructed: true, DerWriter.octetString(content))]),
        ] + (shape.embedded ? [DerWriter.setOf(certificates.map { $0.rawData }, tag: 0xA0)] : [])
            + [shape.strayByte ? DerWriter.node(0x31, signers.flatMap { $0 } + [0xFF]) : DerWriter.set(signers)])
        var encoded = DerWriter.sequence([DerWriter.oid(Oids.signedData), DerWriter.context(0, constructed: true, data)])
        if shape.spoiled { encoded[encoded.count - 1] ^= 1 }
        return encoded
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
        var outside = Shape()
        outside.embedded = false

        XCTAssertTrue(accepts(try token(critical, outside), [critical]))
        XCTAssertFalse(accepts(try token(critical, outside)))
        XCTAssertFalse(accepts(try token(quiet, outside), [quiet]))
        XCTAssertFalse(accepts(try token(none, outside), [none]))
    }

    func test_aTokenHasOneSignerAndNamesItsCertificateExactly() throws {
        let critical = try authority(critical: true, [timeStamping])
        let other = try authority(critical: true, [timeStamping])
        var two = Shape(), hash = Shape(), serial = Shape(), outside = Shape(), none = Shape()
        two.second = other
        hash.hashOfOther = true
        serial.wrongSerial = true
        outside.wrongSerial = true
        outside.embedded = false
        none.withoutEss = true

        XCTAssertFalse(accepts(try token(critical, two)))
        XCTAssertFalse(accepts(try token(critical, hash)))
        XCTAssertFalse(accepts(try token(critical, serial)))
        XCTAssertFalse(accepts(try token(critical, outside), [critical]))
        XCTAssertFalse(accepts(try token(critical, none)))
    }

    func test_theAuthorityCertificateHasToHoldAtTheTimeOfTheStamp() throws {
        let expired = try authority(critical: true, [timeStamping], until: try XCTUnwrap(Pki.signing.adding(days: -1)))
        let later = try authority(critical: true, [timeStamping], from: try XCTUnwrap(Pki.signing.adding(days: 1)))
        let holding = try authority(critical: true, [timeStamping], from: try XCTUnwrap(Pki.signing.adding(days: -1)), until: try XCTUnwrap(Pki.signing.adding(days: 1)))
        var outside = Shape()
        outside.embedded = false

        XCTAssertFalse(accepts(try token(expired)))
        XCTAssertFalse(accepts(try token(later)))
        XCTAssertTrue(accepts(try token(holding)))
        XCTAssertFalse(accepts(try token(expired, outside), [expired]))
        XCTAssertFalse(accepts(try token(later, outside), [later]))
        XCTAssertTrue(accepts(try token(holding, outside), [holding]))
    }

    func test_aTokenMayNameItsSignerWithTheSHA1SigningCertificateAlone() throws {
        let critical = try authority(critical: true, [timeStamping])
        var only = Shape(), both = Shape(), wrong = Shape(), wrongAlone = Shape(), wrongTwo = Shape()
        only.version1 = true
        only.version2 = false
        both.version1 = true
        wrong.version1 = true
        wrong.version1Other = true
        wrongAlone.version1 = true
        wrongAlone.version1Other = true
        wrongAlone.version2 = false
        wrongTwo.version1 = true
        wrongTwo.version2Other = true

        XCTAssertTrue(accepts(try token(critical, only)))
        XCTAssertTrue(accepts(try token(critical, both)))
        XCTAssertFalse(accepts(try token(critical, wrong)))
        XCTAssertFalse(accepts(try token(critical, wrongAlone)))
        XCTAssertFalse(accepts(try token(critical, wrongTwo)))
    }

    func test_aSignerNamedByItsKeyIdentifierIsCheckedAgainstTheCertificateWhenThereIsOne() throws {
        let critical = try authority(critical: true, [timeStamping])
        var inside = Shape(), outside = Shape(), serial = Shape()
        inside.keyIdentifier = true
        outside.keyIdentifier = true
        outside.embedded = false
        serial.keyIdentifier = true
        serial.wrongSerial = true

        XCTAssertTrue(accepts(try token(critical, inside)))
        XCTAssertTrue(accepts(try token(critical, outside), [critical]))
        XCTAssertFalse(accepts(try token(critical, serial)))
    }

    func test_theIssuerSerialNamesExactlyOneIssuer() throws {
        let critical = try authority(critical: true, [timeStamping])
        var two = Shape()
        two.twoNames = true

        XCTAssertFalse(accepts(try token(critical, two)))
    }

    func test_aByteAfterTheFirstSignerThatIsNoSignerKeepsTheCmsReadableAndMakesTheTokenUnreadable() throws {
        let critical = try authority(critical: true, [timeStamping])
        var stray = Shape()
        stray.strayByte = true
        let encoded = try token(critical, stray)

        let cms = try XCTUnwrap(CmsSignature.parse(encoded))

        XCTAssertEqual(cms.signerCount, 2)
        XCTAssertNil(Rfc3161Token.tryDecode(encoded))
        XCTAssertNotNil(Rfc3161Token.tryDecode(try token(critical)))
    }

    func test_aHashTheCertificateIdNamesHasToBeKnownAndNothingMayFollowTheParts() throws {
        let critical = try authority(critical: true, [timeStamping])
        func shaped(_ shape: EssShape) throws -> [UInt8] {
            var value = Shape()
            value.essShape = shape
            return try token(critical, value)
        }

        XCTAssertTrue(accepts(try shaped(.plain)))
        XCTAssertFalse(accepts(try shaped(.unknownHash)))
        XCTAssertFalse(accepts(try shaped(.trailingId)))
        XCTAssertFalse(accepts(try shaped(.trailingSerial)))
        XCTAssertFalse(accepts(try shaped(.trailingName)))
    }

    func test_aSignatureThatDoesNotHoldMakesTheTokenUnreadable() throws {
        let critical = try authority(critical: true, [timeStamping])
        var spoiled = Shape()
        spoiled.spoiled = true

        XCTAssertNotNil(Rfc3161Token.tryDecode(try token(critical)))
        XCTAssertNil(Rfc3161Token.tryDecode(try token(critical, spoiled)))
    }

    func test_everyCertificateIdHasToDecodeAndThePoliciesAreOneSequenceAtMost() throws {
        let critical = try authority(critical: true, [timeStamping])
        func shaped(_ shape: EssShape) throws -> [UInt8] {
            var value = Shape()
            value.essShape = shape
            return try token(critical, value)
        }

        XCTAssertTrue(accepts(try shaped(.secondOther)))
        XCTAssertFalse(accepts(try shaped(.secondMalformed)))
        XCTAssertTrue(accepts(try shaped(.policiesEmpty)))
        XCTAssertTrue(accepts(try shaped(.policiesGood)))
        XCTAssertFalse(accepts(try shaped(.policiesNull)))
        XCTAssertFalse(accepts(try shaped(.policiesTwo)))
    }

    func test_aMainSignatureWithAByteAfterItsFirstSignerStaysValid() throws {
        var request = SignatureKit.request(pki)
        request.format = .pkcs7Detached
        let file = try PdfSigner.sign(SignatureKit.plain(), request)

        let other = SignatureKit.splice(file) { content in
            guard let cms = try? SignatureVerificationTests.byFramework(content, self.pki.leaf, .sha256) else { return [] }
            return SignatureExtraKit.withStrayByte(cms)
        }

        let reports = try SignatureKit.verify(other)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.verdict, .valid)
    }
}
#endif
