#if canImport(Security)
import XCTest
import Security
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureVerificationTests.cs: the same cases, except that the RSA-PSS
// case of A_signature_made_by_the_framework_verifies is left out: SignatureCrypto signs with PKCS#1 only, and the
// verifier's PSS path has no signer here to make a file for it. The "framework" signatures are written by
// `byFramework` below, which stands for SignedCms.ComputeSignature.

final class SignatureVerificationTests: XCTestCase {
    private let pki = Pki.instance

    private func signed(_ change: (inout PdfSignRequest) -> Void = { _ in }) throws -> [UInt8] {
        var request = SignatureKit.request(pki)
        change(&request)
        return try PdfSigner.sign(SignatureKit.plain(), request)
    }

    private func single(_ reports: [SignatureReport], line: UInt = #line) throws -> SignatureReport {
        XCTAssertEqual(reports.count, 1, line: line)
        return try XCTUnwrap(reports.first, line: line)
    }

    func test_withoutTrustAnchorsTheSignerIsValidButNotTrusted() throws {
        let report = try single(PdfSignatureVerifier.verify(signed()))

        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.problems.contains(.untrustedSigner))
        XCTAssertEqual(report.signerName, "Ada Lovelace")
    }

    func test_aSelfSignedCertificateIsTrustedOnlyWhenTheCallerSaysSo() throws {
        let file = try PdfSigner.sign(SignatureKit.plain(), PdfSignRequest(pki.selfSigned, Pki.signing))

        XCTAssertEqual(try single(PdfSignatureVerifier.verify(file, pki.trusting)).verdict, .validButUntrusted)
        var pinned = VerifyOptions()
        pinned.trustAnchors = [pki.selfSigned]
        XCTAssertEqual(try single(PdfSignatureVerifier.verify(file, pinned)).verdict, .valid)
    }

    func test_aCertificateOutsideItsValidityAtSigningTimeIsNotTrusted() throws {
        for year in [2024, 2041] {
            let file = try signed { $0.time = DateTimeOffset(year, 6, 1, 0, 0, 0) }

            let report = try single(SignatureKit.verify(file))
            XCTAssertEqual(report.verdict, .validButUntrusted, "\(year)")
            XCTAssertTrue(report.problems.contains(.certificateNotValid), "\(year)")
            XCTAssertFalse(report.problems.contains(.untrustedSigner), "\(year)")
        }
    }

    func test_aChangedByteInTheSignedRangeBreaksTheDigest() throws {
        let tampered = TestPdf.replace(try signed(), "Contract page 1", "Contract page 9")

        let report = try single(SignatureKit.verify(tampered))
        XCTAssertEqual(report.verdict, .broken)
        XCTAssertEqual(report.problems, [.digestMismatch])
        XCTAssertEqual(report.sentence, "The signature by Ada Lovelace is not valid.")
    }

    func test_aChangedSignatureValueIsABadSignature() throws {
        var file = try signed()
        let found = SignatureScan.find(file)[0]
        let length = try XCTUnwrap(CmsSignature.parse((found.dictionary["Contents"] as! PdfString).bytes)).length
        let range = SignatureKit.byteRange(found)
        let last = range[1] + 1 + 2 * length - 1
        file[last] = file[last] == UInt8(ascii: "0") ? UInt8(ascii: "1") : UInt8(ascii: "0")

        let report = try single(SignatureKit.verify(file))

        XCTAssertEqual(report.verdict, .broken)
        XCTAssertTrue(report.problems.contains { $0 == .badSignature || $0 == .badByteRange })
    }

    func test_dataAfterTheSignatureInsideContentsIsRefused() throws {
        var file = try signed()
        let range = SignatureKit.byteRange(SignatureScan.find(file)[0])
        file[range[2] - 2] = UInt8(ascii: "1")

        XCTAssertEqual(try single(SignatureKit.verify(file)).verdict, .broken)
    }

    func test_aSignatureFormatWeDoNotReadIsUnknownNotValid() throws {
        let file = TestPdf.replace(try signed(), "/ETSI.CAdES.detached", "/ETSI.CAdES.detachee")

        let report = try single(SignatureKit.verify(file))

        XCTAssertEqual(report.verdict, .unknown)
        XCTAssertEqual(report.problems, [.unsupportedFormat])
    }

    func test_anUnsignedFileHasNoReportsAndJunkDoesNotLookLikeASignature() throws {
        XCTAssertTrue(try SignatureKit.verify(SignatureKit.plain()).isEmpty)

        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        pdf.stream(3, "", "text with /ByteRange [0 1 2 3] and /Contents <00> inside a stream")
        XCTAssertTrue(try SignatureKit.verify(pdf.finish()).isEmpty)
    }

    func test_anEmbeddedTimeStampFixesTheSigningTimeAndRaisesTheLevel() throws {
        let network = FakeNetwork()
        network.stampTime = Pki.signing.adding(seconds: 7200)!
        let file = try signed { $0.timestamp = TimestampSettings(network, url: "http://tsa.test/") }

        let report = try single(SignatureKit.verify(file))

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertEqual(report.level, .t)
        XCTAssertEqual(report.timestampTime, Pki.signing.adding(seconds: 7200))
        XCTAssertEqual(report.timestampTime, report.timeUsed)
        XCTAssertEqual(network.requests, ["http://tsa.test/"])
    }

    func test_aCertificateThatExpiredBeforeTheTimeStampIsNotValidAtThatTime() throws {
        let network = FakeNetwork()
        network.stampTime = Pki.expiry.adding(days: 90)!
        var request = PdfSignRequest(pki.shortLived, Pki.signing)
        request.chain = pki.chain
        request.timestamp = TimestampSettings(network, url: "http://tsa.test/")

        let report = try single(SignatureKit.verify(PdfSigner.sign(SignatureKit.plain(), request)))

        XCTAssertTrue(report.problems.contains(.certificateNotValid))
        XCTAssertEqual(report.verdict, .validButUntrusted)
    }

    func test_aCertificateThatHasExpiredSinceIsStillGoodForATimeStampedSignature() throws {
        let network = FakeNetwork()
        var request = PdfSignRequest(pki.shortLived, Pki.signing)
        request.chain = pki.chain
        request.timestamp = TimestampSettings(network, url: "http://tsa.test/")

        let report = try single(SignatureKit.verify(PdfSigner.sign(SignatureKit.plain(), request)))

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(pki.shortLived.notAfter < currentTime(), "The test needs the certificate to have expired by the clock.")
    }

    func test_aDamagedTimeStampIsReportedAndTheClaimedTimeIsUsed() throws {
        let network = FakeNetwork()
        var file = try signed { $0.timestamp = TimestampSettings(network, url: "http://tsa.test/") }
        // The token's own signature sits near the end of the CMS, before the zero padding.
        let found = SignatureScan.find(file)[0]
        let cms = try XCTUnwrap(CmsSignature.parse((found.dictionary["Contents"] as! PdfString).bytes))
        let range = SignatureKit.byteRange(found)
        let at = range[1] + 1 + 2 * (cms.length - 8)
        file[at] = file[at] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")

        let report = try single(SignatureKit.verify(file))

        XCTAssertTrue(report.problems.contains(.timestampInvalid))
        XCTAssertNil(report.timestampTime)
        XCTAssertNotEqual(report.verdict, .valid)
    }

    func test_aTimeStampServerThatFailsStopsTheSignature() throws {
        let network = FakeNetwork()
        network.stampDown = true
        XCTAssertThrowsError(try signed { $0.timestamp = TimestampSettings(network, url: "http://tsa.test/") }) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, SignatureText.noTimestamp)
        }
        XCTAssertThrowsError(try signed { $0.timestamp = TimestampSettings(network) })
        XCTAssertThrowsError(try signed { $0.level = .t })
    }

    func test_signedDataThatIsNotASignatureNeverThrows() throws {
        let file = try signed()
        var random = SeededRandom(5)
        let range = SignatureKit.byteRange(SignatureScan.find(file)[0])
        let digits = Array("0123456789ABCDEF".utf8)
        for _ in 0..<40 {
            var copy = file
            for _ in 0..<6 {
                let at = range[1] + 1 + Int.random(in: 0..<(range[2] - range[1] - 2), using: &random)
                copy[at] = digits[Int.random(in: 0..<16, using: &random)]
            }
            XCTAssertNotEqual(try single(SignatureKit.verify(copy)).verdict, .valid)
        }
    }

    /// What SignedCms.ComputeSignature makes: a detached CMS with the certificate and the chain, a signing time and, unless `attributes` is off, signed attributes.
    static func byFramework(_ content: [UInt8], _ certificate: X509Certificate, _ digest: HashAlgorithmName, attributes: Bool = true) throws -> [UInt8] {
        let pki = Pki.instance
        let ec = certificate.publicKeyAlgorithm == Oids.ecPublicKey
        let hash = SignatureCrypto.hash(digest, content)
        let digestOid = digest == .sha1 ? "1.3.14.3.2.26" : "2.16.840.1.101.3.4.2.1"
        let attributeList = [
            DerWriter.sequence([DerWriter.oid(Oids.contentType), DerWriter.setOf([DerWriter.oid(Oids.data)])]),
            DerWriter.sequence([DerWriter.oid(Oids.messageDigest), DerWriter.setOf([DerWriter.octetString(hash)])]),
            DerWriter.sequence([DerWriter.oid(Oids.signingTime), DerWriter.setOf([DerWriter.utcTime(Pki.signing)])]),
        ]
        let signedHash = attributes ? SignatureCrypto.hash(digest, DerWriter.setOf(attributeList)) : hash
        let key = try XCTUnwrap(certificate.privateKey)
        let signature = try SignatureCrypto.sign(key, signedHash, digest, ec: ec)
        var signer = [
            DerWriter.integer(1),
            DerWriter.sequence([certificate.issuerName, DerWriter.integer(certificate.serialNumber)]),
            CmsBuilder.algorithmIdentifier(digestOid, withNull: true),
        ]
        if attributes { signer.append(DerWriter.setOf(attributeList, tag: 0xA0)) }
        signer.append(ec ? CmsBuilder.algorithmIdentifier(Oids.ecdsaWith(digest), withNull: false) : CmsBuilder.algorithmIdentifier(Oids.rsaEncryption, withNull: true))
        signer.append(DerWriter.octetString(signature))
        let data = DerWriter.sequence([
            DerWriter.integer(1),
            DerWriter.set([CmsBuilder.algorithmIdentifier(digestOid, withNull: true)]),
            DerWriter.sequence([DerWriter.oid(Oids.data)]),
            DerWriter.setOf(([certificate] + pki.chain).map { $0.rawData }, tag: 0xA0),
            DerWriter.set([DerWriter.sequence(signer)]),
        ])
        return DerWriter.sequence([DerWriter.oid(Oids.signedData), DerWriter.context(0, constructed: true, data)])
    }

    func test_aSignatureMadeByTheFrameworkVerifies() throws {
        for (kind, attributes) in [("pkcs1", true), ("ecdsa", true), ("pkcs1", false), ("ecdsa", false)] {
            let file = try signed { $0.format = .pkcs7Detached }
            let certificate = kind == "ecdsa" ? pki.leafEc : pki.leaf

            let other = SignatureKit.splice(file) { (try? Self.byFramework($0, certificate, .sha256, attributes: attributes)) ?? [] }

            let report = try single(SignatureKit.verify(other))
            XCTAssertEqual(report.verdict, .valid, "\(kind) \(attributes)")
            XCTAssertEqual(report.signerName, kind == "ecdsa" ? "Grace Hopper" : "Ada Lovelace", "\(kind) \(attributes)")
            XCTAssertEqual(report.signingTime, Pki.signing, "\(kind) \(attributes)")
        }
    }

    func test_aSha1SignatureReadsButIsCalledWeak() throws {
        let file = try signed { $0.format = .pkcs7Detached }

        let other = SignatureKit.splice(file) { (try? Self.byFramework($0, self.pki.leaf, .sha1)) ?? [] }

        let report = try single(SignatureKit.verify(other))
        XCTAssertTrue(report.problems.contains(.weakDigest))
        XCTAssertEqual(report.verdict, .validButUntrusted)
    }

    func test_aSignatureOverOtherBytesDoesNotVerifyWhoeverMadeIt() throws {
        let file = try signed { $0.format = .pkcs7Detached }

        let other = SignatureKit.splice(file) { (try? Self.byFramework($0 + [1], self.pki.leaf, .sha256)) ?? [] }

        XCTAssertEqual(try single(SignatureKit.verify(other)).problems, [.digestMismatch])
    }

    func test_aSignatureThatNamesAnotherCertificateThanTheOneItWasMadeWithIsBroken() throws {
        let file = try signed()
        func sign(_ named: X509Certificate, _ content: [UInt8]) -> [UInt8] {
            let key = self.pki.leafEc.privateKey
            let settings = CmsSettings(certificate: named, chain: self.pki.chain, digest: .sha256, cades: true, time: Pki.signing, external: { hash, _ in
                guard let key else { return [] }
                let der = try SignatureCrypto.sign(key, hash, .sha256, ec: true)
                return Self.p1363(der)
            })
            return (try? CmsBuilder.build(Sha256.hash(content), settings, nil)) ?? []
        }

        // Signed with Grace's key under Grace's name, and under Ada's: only the first is what it says.
        XCTAssertEqual(try single(SignatureKit.verify(SignatureKit.splice(file) { sign(self.pki.leafEc, $0) })).verdict, .valid)
        XCTAssertEqual(try single(SignatureKit.verify(SignatureKit.splice(file) { sign(self.pki.leaf, $0) })).verdict, .broken)
    }

    /// An ECDSA signature as r followed by s (IEEE P1363) from its DER sequence, 32 bytes each.
    private static func p1363(_ der: [UInt8]) -> [UInt8] {
        var outer = AsnReader(der)
        guard var sequence = try? outer.readSequence(), let r = try? sequence.readInteger(), let s = try? sequence.readInteger() else { return [] }
        func pad(_ value: AsnInteger) -> [UInt8] { [UInt8](repeating: 0, count: max(0, 32 - value.magnitude.count)) + value.magnitude }
        return pad(r) + pad(s)
    }

    func test_revocationDataASignatureArchivedInItselfIsRead() throws {
        let network = FakeNetwork()
        let answer = try XCTUnwrap(network.post(Pki.ocspUrl, "application/ocsp-request", OcspResponse.buildRequest(pki.leaf, pki.intermediate)))
        let crl = try XCTUnwrap(network.get(Pki.crlUrl))
        let archival = DerWriter.sequence([
            DerWriter.context(0, constructed: true, DerWriter.sequence([crl])),
            DerWriter.context(1, constructed: true, DerWriter.sequence([answer])),
        ])
        let cms = try XCTUnwrap(CmsSignature.parse(SignatureKit.parts(signed()).cms))
        cms.attributes[Oids.revocationArchival] = [archival]

        let data = ValidationData()
        data.readArchival(cms)

        XCTAssertEqual(data.ocsps.count, 1)
        XCTAssertEqual(data.crls.count, 1)
        XCTAssertEqual(data.check(pki.leaf, pki.intermediate).state, .good)
        XCTAssertEqual(data.check(pki.intermediate, pki.root).state, .noData)
    }

    func test_theSystemStoreIsAnOptionThatChangesNothingForAPrivateCa() throws {
        let file = try signed()

        var system = VerifyOptions()
        system.useSystemStore = true
        XCTAssertEqual(try single(PdfSignatureVerifier.verify(file, system)).verdict, .validButUntrusted)
        system.trustAnchors = [pki.root]
        XCTAssertEqual(try single(PdfSignatureVerifier.verify(file, system)).verdict, .valid)
    }

    func test_aFileWithAPasswordIsVerifiedWithIt() throws {
        let id = [UInt8](repeating: 0, count: 16)
        let random = SeededRandom(2)
        let security = PdfSecurity.create(userPassword: "open", ownerPassword: "owner", permissions: .all, strength: .aes256, firstId: id, random: random)
        let encrypted = try PdfDocument.open(SignatureKit.plain()).saveRewrite(PdfSaveOptions(security: security, documentId: id))
        var request = SignatureKit.request(pki)
        request.reason = "Because"
        let file = try PdfSigner.sign(encrypted, request, password: "open")

        var options = pki.trusting
        options.password = "open"
        let report = try single(PdfSignatureVerifier.verify(file, options))

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertEqual(report.reason, "Because")
        XCTAssertThrowsError(try PdfSignatureVerifier.verify(file, pki.trusting)) { XCTAssertTrue($0 is PdfReadException) }
    }
}
#endif
