#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureMalformedDataTests.cs: the same cases. Certificates, answers
// and parameters in a file that do not decode, and a responder that expired after it answered. The PSS file comes from
// SignatureExtraKit, and the certificate whose key usage does not decode is written by CertificateBuilder. The signer
// search is given the odd certificate in front of the signature's own, where the C# inserts it into the list, which
// `CmsSignature` keeps private to its setter.

final class SignatureMalformedDataTests: XCTestCase {
    private let pki = Pki.instance

    private let ocspSigning = "1.3.6.1.5.5.7.3.9"

    private func answerOf(_ network: FakeNetwork) throws -> [UInt8] {
        try XCTUnwrap(network.post(Pki.ocspUrl, "application/ocsp-request", OcspResponse.buildRequest(pki.leaf, pki.intermediate)))
    }

    private func oddExtension(_ oid: String) -> X509Extension {
        X509Extension(oid: oid, critical: false, value: [0xFF, 0x01])
    }

    func test_aResponderThatExpiredAfterItAnsweredStillCounts() throws {
        for revoked in [false, true] {
            let responder = try pki.issuedUntil(Pki.expiry, "Short Responder", .digitalSignature, ocspSigning)
            let network = FakeNetwork()
            network.responder = responder
            network.revoked = revoked
            network.issued = try XCTUnwrap(Pki.signing.adding(days: 1))
            let answer = try XCTUnwrap(OcspResponse.parse(answerOf(network)))

            let state = answer.about(pki.leaf, pki.intermediate).state

            XCTAssertEqual(state, revoked ? .revoked : .good, "\(revoked)")
        }
    }

    func test_aResponderThatWasNotValidWhenItAnsweredSaysNothing() throws {
        let responder = try pki.issuedUntil(Pki.expiry, "Short Responder", .digitalSignature, ocspSigning)
        let network = FakeNetwork()
        network.responder = responder
        network.issued = try XCTUnwrap(Pki.expiry.adding(days: 30))
        let answer = try XCTUnwrap(OcspResponse.parse(answerOf(network)))

        XCTAssertEqual(answer.about(pki.leaf, pki.intermediate).state, .noData)
    }

    func test_aSignerCertificateWithAnExtensionThatDoesNotDecodeIsUntrustedNotFatal() throws {
        for oid in ["2.5.29.15", "2.5.29.37"] {
            let odd = try pki.issuedWith("Odd Signer", oddExtension(oid))
            let first = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))

            var request = PdfSignRequest(odd, try XCTUnwrap(Pki.signing.adding(days: 1)))
            request.chain = pki.chain
            request.fieldName = "Second"
            let second = try PdfSigner.sign(first, request)
            let reports = try SignatureKit.verify(second)

            XCTAssertEqual(reports.count, 2, oid)
            XCTAssertTrue(reports.last?.problems.contains(.untrustedSigner) ?? false, oid)
        }
    }

    func test_anOcspAnswerWhoseCertificateHasAPurposeThatDoesNotDecodeSaysNothing() throws {
        let responder = try pki.issuedWith("Odd Responder", oddExtension("2.5.29.37"))
        let network = FakeNetwork()
        network.responder = responder
        let answer = try XCTUnwrap(OcspResponse.parse(answerOf(network)))

        XCTAssertEqual(answer.about(pki.leaf, pki.intermediate).state, .noData)
    }

    func test_PSSParametersWithAUniversalTagBreakThatSignatureAndNothingElse() throws {
        var request = SignatureKit.request(pki)
        request.format = .pkcs7Detached
        let file = try PdfSigner.sign(SignatureKit.plain(), request)
        let forged = SignatureKit.splice(file) { content in
            guard var cms = try? SignatureExtraKit.signedWithPss(content, self.pki.leaf, .sha256) else { return [] }
            let at = cms.indexOf([0xA2, 0x03, 0x02, 0x01, 0x20])
            XCTAssertNotNil(at)
            if let at, at > 0 { cms[at] = 0x02 }
            return cms
        }
        var other = PdfSignRequest(pki.leafEc, try XCTUnwrap(Pki.signing.adding(days: 1)))
        other.chain = pki.chain
        other.fieldName = "Second"
        let second = try PdfSigner.sign(forged, other)

        let reports = try SignatureKit.verify(second)

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].verdict, .broken)
        XCTAssertEqual(reports[1].verdict, .valid)
    }

    func test_archivedRevocationDataWithAUniversalTagAddsNothing() throws {
        let file = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        let cms = try XCTUnwrap(CmsSignature.parse(SignatureKit.parts(file).cms))
        cms.attributes[Oids.revocationArchival] = [DerWriter.sequence([DerWriter.integer(0)])]

        let data = ValidationData()
        data.readArchival(cms)

        XCTAssertTrue(data.ocsps.isEmpty)
        XCTAssertTrue(data.crls.isEmpty)
    }

    func test_anOcspGoodDatedAfterTheAnswerThatCarriesItSaysNothing() throws {
        let network = FakeNetwork()
        network.issued = try XCTUnwrap(Pki.signing.adding(days: 1))
        network.ocspThisUpdate = try XCTUnwrap(Pki.signing.adding(days: 11))
        let answer = try XCTUnwrap(OcspResponse.parse(answerOf(network)))

        XCTAssertEqual(answer.about(pki.leaf, pki.intermediate).state, .noData)
    }

    func test_aCrlForCACertificatesSaysNothingOfOneWhoseBasicConstraintsDoNotDecode() throws {
        let odd = try pki.issuedWith("Odd Constraints", oddExtension("2.5.29.19"))
        let network = FakeNetwork()
        network.crlExtension = X509Extension(oid: "2.5.29.28", critical: true, value: [0x30, 0x03, 0x81, 0x01, 0xFF])
        let crl = try XCTUnwrap(Crl.parse(XCTUnwrap(network.get(Pki.crlUrl))))

        XCTAssertEqual(crl.about(odd, pki.intermediate).state, .noData)
    }

    func test_aCrlIssuerWhoseKeyUsageDoesNotDecodeSignsNothing() throws {
        let odd = try SignatureExtraKit.selfSigned(subject: pki.intermediate.subjectName,
                                                   extensions: [X509Extension(oid: "2.5.29.15", critical: true, value: [0xFF, 0x01])])
        let crl = try XCTUnwrap(Crl.parse(XCTUnwrap(FakeNetwork().get(Pki.crlUrl))))

        XCTAssertEqual(crl.about(pki.leaf, odd).state, .noData)
    }

    func test_aCertificateWhoseSubjectKeyIdentifierDoesNotDecodeIsPassedOverWhenTheSignerIsLookedFor() throws {
        let cms = try XCTUnwrap(CmsSignature.parse(SignatureExtraKit.signedByKeyIdentifier([1, 2, 3], pki.leaf)))
        let odd = try pki.issuedWith("Odd Identifier", oddExtension("2.5.29.14"))

        XCTAssertEqual(cms.findSigner(in: [odd] + cms.certificates)?.thumbprint, pki.leaf.thumbprint)
    }
}
#endif
