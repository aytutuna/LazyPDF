#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// No C# twin: the C# leaves the chain to X509Chain, which refuses a chain with a critical extension it does not know,
// with name constraints or policy constraints, and one that stops at an anchor which is not a root. The chain of the
// Swift engine is built by CertificateTrust, and these cases pin what it refuses.

final class SignatureChainRulesTests: XCTestCase {
    private let pki = Pki.instance

    private func authority(_ extra: [X509Extension] = []) throws -> X509Certificate {
        try SignatureExtraKit.issue("Partner CA", under: pki.intermediate,
                                    [CertificateBuilder.basicConstraints(authority: true), CertificateBuilder.keyUsage([.keyCertSign, .crlSign])] + extra)
    }

    private func leaf(under issuer: X509Certificate, _ extra: [X509Extension] = []) throws -> X509Certificate {
        try SignatureExtraKit.issue("Signer", under: issuer,
                                    [CertificateBuilder.basicConstraints(authority: false), CertificateBuilder.keyUsage([.digitalSignature, .nonRepudiation])] + extra)
    }

    private func verdict(_ signer: X509Certificate, _ chain: [X509Certificate], anchors: [X509Certificate]? = nil) throws -> SignatureReport {
        var request = PdfSignRequest(signer, Pki.signing)
        request.chain = chain
        var options = VerifyOptions()
        options.trustAnchors = anchors ?? [pki.root]
        let reports = try PdfSignatureVerifier.verify(PdfSigner.sign(SignatureKit.plain(), request), options)
        XCTAssertEqual(reports.count, 1)
        return try XCTUnwrap(reports.first)
    }

    private let constraint = DerWriter.sequence([
        DerWriter.context(0, constructed: true, DerWriter.sequence([DerWriter.sequence([DerWriter.ia5String("partner.example", tag: 0x82)])])),
    ])

    func test_aChainWithoutRestrictionsIsTrusted() throws {
        let ca = try authority()
        let report = try verdict(leaf(under: ca), [ca, pki.intermediate, pki.root])

        XCTAssertEqual(report.verdict, .valid)
    }

    func test_aCriticalNameConstraintOnACertificateOfTheChainMakesTheSignerUntrusted() throws {
        let ca = try authority([X509Extension(oid: "2.5.29.30", critical: true, value: constraint)])
        let report = try verdict(leaf(under: ca), [ca, pki.intermediate, pki.root])

        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.problems.contains(.untrustedSigner))
    }

    func test_nameConstraintsThatAreNotMarkedCriticalAreNotEnforcedEitherSoTheyRefuseTheChain() throws {
        let ca = try authority([X509Extension(oid: "2.5.29.30", critical: false, value: constraint)])

        XCTAssertEqual(try verdict(leaf(under: ca), [ca, pki.intermediate, pki.root]).verdict, .validButUntrusted)
    }

    func test_policyConstraintsMakeTheSignerUntrusted() throws {
        let ca = try authority([X509Extension(oid: "2.5.29.36", critical: true, value: DerWriter.sequence([DerWriter.node(0x80, [0])]))])

        XCTAssertEqual(try verdict(leaf(under: ca), [ca, pki.intermediate, pki.root]).verdict, .validButUntrusted)
    }

    func test_aCriticalExtensionNobodyHereKnowsMakesTheSignerUntrustedButANonCriticalOneDoesNot() throws {
        let ca = try authority()
        let critical = try leaf(under: ca, [X509Extension(oid: "1.2.3.4.5", critical: true, value: DerWriter.sequence([]))])
        let quiet = try leaf(under: ca, [X509Extension(oid: "1.2.3.4.5", critical: false, value: DerWriter.sequence([]))])

        XCTAssertEqual(try verdict(critical, [ca, pki.intermediate, pki.root]).verdict, .validButUntrusted)
        XCTAssertEqual(try verdict(quiet, [ca, pki.intermediate, pki.root]).verdict, .valid)
    }

    func test_anAnchorThatIsNotARootLeavesTheChainPartial() throws {
        let file = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        for anchor in [pki.intermediate] {
            var options = VerifyOptions()
            options.trustAnchors = [anchor]
            let reports = try PdfSignatureVerifier.verify(file, options)
            XCTAssertEqual(reports.count, 1)
            XCTAssertEqual(reports.first?.verdict, .validButUntrusted, anchor.subject)
            XCTAssertTrue(reports.first?.problems.contains(.untrustedSigner) ?? false, anchor.subject)
        }
        XCTAssertEqual(try SignatureKit.verify(file).first?.verdict, .valid)
    }

    func test_aSignerInTheAnchorsIsTrustedWhateverSignedIt() throws {
        var options = VerifyOptions()
        options.trustAnchors = [pki.leaf]

        let result = CertificateTrust.evaluate(pki.leaf, [], Pki.signing, options)

        XCTAssertTrue(result.trusted)
        XCTAssertTrue(result.timeValid)
        XCTAssertEqual(result.chain.count, 1)
        XCTAssertFalse(CertificateTrust.evaluate(pki.leafEc, [], Pki.signing, options).trusted)
    }

    func test_aSignerInTheAnchorsKeepsItsFullChainWhenARootIsTrustedToo() throws {
        var options = VerifyOptions()
        options.trustAnchors = [pki.root, pki.leaf]

        let result = CertificateTrust.evaluate(pki.leaf, pki.chain, Pki.signing, options)

        XCTAssertTrue(result.trusted)
        XCTAssertTrue(result.chain.count > 1)
    }

    func test_aSignerInTheAnchorsTheSystemStoreDoesNotKnowIsTrustedByItself() throws {
        var options = VerifyOptions()
        options.trustAnchors = [pki.leaf]
        options.useSystemStore = true

        let result = CertificateTrust.evaluate(pki.leaf, [], Pki.signing, options)

        XCTAssertTrue(result.trusted)
        XCTAssertEqual(result.chain.count, 1)
    }

    func test_aSignerInTheAnchorsStillNeedsAKeyUsageForSigning() throws {
        let encipher = try pki.issued("Encipher", [.keyEncipherment])
        var options = VerifyOptions()
        options.trustAnchors = [encipher]

        XCTAssertFalse(CertificateTrust.evaluate(encipher, [], Pki.signing, options).trusted)
    }

    func test_aSignerInTheAnchorsIsNotTimeValidAfterItExpires() throws {
        var options = VerifyOptions()
        options.trustAnchors = [pki.shortLived]

        let result = CertificateTrust.evaluate(pki.shortLived, [], try XCTUnwrap(Pki.expiry.adding(days: 1)), options)

        XCTAssertTrue(result.trusted)
        XCTAssertFalse(result.timeValid)
    }

    func test_aCriticalSubjectDirectoryAttributesExtensionMakesTheSignerUntrusted() throws {
        let ca = try authority()
        let critical = try leaf(under: ca, [X509Extension(oid: "2.5.29.9", critical: true, value: DerWriter.sequence([]))])
        let quiet = try leaf(under: ca, [X509Extension(oid: "2.5.29.9", critical: false, value: DerWriter.sequence([]))])

        XCTAssertEqual(try verdict(critical, [ca, pki.intermediate, pki.root]).verdict, .validButUntrusted)
        XCTAssertEqual(try verdict(quiet, [ca, pki.intermediate, pki.root]).verdict, .valid)
    }

    func test_certificatePoliciesThatDoNotDecodeMakeTheSignerUntrusted() throws {
        let ca = try authority()
        let policies = DerWriter.sequence([DerWriter.sequence([DerWriter.oid("2.5.29.32.0")])])
        let good = try leaf(under: ca, [X509Extension(oid: "2.5.29.32", critical: false, value: policies)])
        let broken = try leaf(under: ca, [X509Extension(oid: "2.5.29.32", critical: false, value: [0xFF, 0x01])])
        let brokenCritical = try leaf(under: ca, [X509Extension(oid: "2.5.29.32", critical: true, value: [0xFF, 0x01])])

        XCTAssertEqual(try verdict(good, [ca, pki.intermediate, pki.root]).verdict, .valid)
        XCTAssertEqual(try verdict(broken, [ca, pki.intermediate, pki.root]).verdict, .validButUntrusted)
        XCTAssertEqual(try verdict(brokenCritical, [ca, pki.intermediate, pki.root]).verdict, .validButUntrusted)
    }

    func test_anAnchorThatIsSelfIssuedButSignedByAnotherKeyIsNotARoot() throws {
        // A link certificate: the name of the root, a new key, signed by the old key of the root.
        let key = try SignatureCrypto.newRsaKey(2048)
        let info = try CertificateBuilder.publicKeyInfo(key)
        let der = try CertificateBuilder.build(subject: pki.root.subjectName, issuer: pki.root.subjectName, publicKeyInfo: info,
                                               notBefore: Pki.notBefore, notAfter: Pki.notAfter, serial: CertificateBuilder.serialNumber(),
                                               extensions: [CertificateBuilder.basicConstraints(authority: true), CertificateBuilder.keyUsage([.keyCertSign, .crlSign])],
                                               issuerKey: try XCTUnwrap(pki.root.privateKey))
        let link = try XCTUnwrap(X509Certificate(der))
        link.privateKey = key
        let signer = try leaf(under: link)

        let report = try verdict(signer, [link], anchors: [link])

        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.problems.contains(.untrustedSigner))
        XCTAssertEqual(try verdict(try leaf(under: pki.root), [], anchors: [pki.root]).verdict, .valid)
        // The chain ends at the link as at any anchor, so the root next to it changes nothing (X509Chain does the same).
        XCTAssertEqual(try verdict(signer, [link], anchors: [link, pki.root]).verdict, .validButUntrusted)
    }

    func test_aRootSignedWithPSSIsTrustedWhenTheCallerTrustsIt() throws {
        let root = try SignatureExtraKit.selfSignedWithPss("Pss Root")
        let signer = try leaf(under: root)

        let report = try verdict(signer, [], anchors: [root])

        XCTAssertEqual(report.verdict, .valid)
    }

    func test_aPSSRootIsTrustedOnlyWithTheMaskFunctionSaltAndSignatureItDeclares() throws {
        let sha1 = "1.3.14.3.2.26"
        func verdict(of root: X509Certificate) throws -> SignatureVerdict {
            try self.verdict(try leaf(under: root), [], anchors: [root]).verdict
        }

        XCTAssertEqual(try verdict(of: SignatureExtraKit.selfSignedWithPss("Pss Variant")), .valid)
        XCTAssertEqual(try verdict(of: SignatureExtraKit.selfSignedWithPss("Pss Variant", trailer: 1)), .valid)
        XCTAssertEqual(try verdict(of: SignatureExtraKit.selfSignedWithPss("Pss Variant", maskHash: sha1)), .validButUntrusted)
        XCTAssertEqual(try verdict(of: SignatureExtraKit.selfSignedWithPss("Pss Variant", mask: "1.2.3.4")), .validButUntrusted)
        XCTAssertEqual(try verdict(of: SignatureExtraKit.selfSignedWithPss("Pss Variant", trailer: 2)), .validButUntrusted)
        XCTAssertEqual(try verdict(of: SignatureExtraKit.selfSignedWithPss("Pss Variant", salt: 20)), .validButUntrusted)
        XCTAssertEqual(try verdict(of: SignatureExtraKit.selfSignedWithPss("Pss Variant", spoiled: true)), .validButUntrusted)
    }

    func test_aRootWhoseSignatureCannotBeCheckedHereIsNotTrusted() throws {
        // The signature algorithm of the root says MD5 with RSA, which nothing here checks (.NET trusts such a root).
        let original = try SignatureExtraKit.selfSigned(subject: X509Certificate.name("CN=Md5 Root"),
                                                        extensions: [CertificateBuilder.basicConstraints(authority: true), CertificateBuilder.keyUsage([.keyCertSign])])
        let sha256: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
        var der = original.rawData
        // Only the algorithm of the certificate, the last one, not the one inside the tbs that the signature covers.
        var last: Int?
        while let at = der.indexOf(sha256, from: (last ?? -1) + 1) { last = at }
        let at = try XCTUnwrap(last)
        der.replaceSubrange(at..<at + sha256.count, with: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x04])
        let root = try XCTUnwrap(X509Certificate(der))
        root.privateKey = original.privateKey
        let signer = try leaf(under: root)

        let report = try verdict(signer, [], anchors: [root])

        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.problems.contains(.untrustedSigner))
    }
}
#endif
