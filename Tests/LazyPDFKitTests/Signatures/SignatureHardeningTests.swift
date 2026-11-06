#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureHardeningTests.cs: the same cases, with these differences.
// Malformed_PSS_parameters has no PSS signer to make its file (SignatureCrypto signs with PKCS#1 only), so the CMS is
// written here with a PSS algorithm identifier whose salt length is an OCTET STRING, over the PKCS#1 signature of
// byFramework. The PFX half of An_imported_id_keeps_its_key_in_memory_and_the_file_is_protected_with_AES is left out
// (exportPfx and importPfx throw on this platform, and the AES and RSACng checks have no twin); the id is made and signs.
// PdfPig has no twin: the page count of the appearance test is read by PdfDocument.

final class SignatureHardeningTests: XCTestCase {
    private let pki = Pki.instance
    private let stampUrl = "http://tsa.test/"
    private let timeStamping = "1.3.6.1.5.5.7.3.8"
    private let emailProtection = "1.3.6.1.5.5.7.3.4"
    private let ocspSigning = "1.3.6.1.5.5.7.3.9"

    private func one(_ file: [UInt8], line: UInt = #line) throws -> SignatureReport {
        let reports = try SignatureKit.verify(file)
        XCTAssertEqual(reports.count, 1, line: line)
        return try XCTUnwrap(reports.first, line: line)
    }

    private func by(_ certificate: X509Certificate) -> PdfSignRequest {
        SignatureObjects.request(certificate, Pki.signing)
    }

    private func archived(_ network: FakeNetwork) -> PdfSignRequest {
        SignatureObjects.leafRequest {
            $0.timestamp = TimestampSettings(network, url: self.stampUrl)
            $0.level = .lt
        }
    }

    private func checkFirst(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    // ---- changes after signing

    private func retitled(_ file: [UInt8], _ count: Int) throws -> [UInt8] {
        var file = file
        for i in 0..<count {
            file = try SignatureTestHelpers.edit(file) { d in
                var metadata = DocumentMetadata.read(d)
                metadata.title = "Title \(i)"
                try metadata.write(d)
            }
        }
        return file
    }

    // An object the update does not list but a scanning viewer would find, closed by a tail that points at the old table.
    private func withUnlistedCopy(_ file: [UInt8], _ lead: String) throws -> [UInt8] {
        let document = try PdfDocument.open(file)
        let contents = try XCTUnwrap(document.pages[0].dictionary["Contents"] as? PdfReference).number
        let body = "BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET"
        let tail = "\n\(lead)\(contents) 0 obj\n<</Length \(body.unicodeScalars.count)>>\nstream\n\(body)\nendstream\nendobj\nxref\ntrailer\n<</Size \(document.nextObjectNumber)\(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>\nstartxref\n\(document.startXref)\n%%EOF\n"
        return file + TestPdf.latin(tail)
    }

    func test_anUnlistedObjectInTheMiddleOfALineIsFoundLikeOneAtItsStart() throws {
        let certified = try SignatureTestHelpers.certified(.annotate)

        XCTAssertEqual(try checkFirst(withUnlistedCopy(certified, "% ")).verdict, .changedAfterSigning)
        XCTAssertEqual(try checkFirst(withUnlistedCopy(certified, "")).verdict, .changedAfterSigning)
        XCTAssertEqual(try checkFirst(retitled(certified, 1)).verdict, .valid)
    }

    func test_manyLaterUpdatesDoNotHideAnUnlistedObject() throws {
        let many = try retitled(SignatureTestHelpers.certified(.annotate), 20)

        XCTAssertEqual(try checkFirst(many).verdict, .valid)
        XCTAssertEqual(try checkFirst(withUnlistedCopy(many, "")).verdict, .changedAfterSigning)
    }

    func test_seventyLaterUpdatesAreAllRead() throws {
        let many = try retitled(SignatureTestHelpers.certified(.annotate), 70)

        XCTAssertEqual(try checkFirst(many).verdict, .valid)
    }

    func test_moreUpdatesThanTheCheckerReadsLeaveTheFileUncheckedAndSoChanged() throws {
        let flooded = try retitled(SignatureTestHelpers.certified(.annotate), 260)

        try SignatureRawKit.assertUnreadable(flooded)
    }

    func test_aSignatureThatRunsToTheEndOfAFileWithBlankBytesAfterTheMarkerIsValid() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        for blank in [" \n", "\n\n", "\r\n\r\n", " \n \n"] {
            let padded = signed + TestPdf.latin(blank)
            let extra = blank.unicodeScalars.count

            let report = try one(SignatureAttackTests.resign(padded) { a, b, end in (a, b, end + extra) })

            XCTAssertEqual(report.verdict, .valid, "\(Array(blank.utf8))")
            XCTAssertTrue(report.coversWholeFile, "\(Array(blank.utf8))")
        }
    }

    func test_blankBytesAreAllARangeMayRunPastTheRevision() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        let padded = signed + TestPdf.latin("\n\n12 0 obj\n<<>>\nendobj\n")

        let report = try one(SignatureAttackTests.resign(padded) { a, b, _ in (a, b, padded.count) })

        XCTAssertEqual(report.verdict, .broken)
    }

    // ---- what makes a signature

    // What SignatureVerificationTests.byFramework makes, with an RSASSA-PSS algorithm identifier whose salt length is an OCTET STRING.
    private func malformedPss(_ content: [UInt8]) throws -> [UInt8] {
        let certificate = pki.leaf
        let attributeList = [
            DerWriter.sequence([DerWriter.oid(Oids.contentType), DerWriter.setOf([DerWriter.oid(Oids.data)])]),
            DerWriter.sequence([DerWriter.oid(Oids.messageDigest), DerWriter.setOf([DerWriter.octetString(SignatureCrypto.hash(.sha256, content))])]),
            DerWriter.sequence([DerWriter.oid(Oids.signingTime), DerWriter.setOf([DerWriter.utcTime(Pki.signing)])]),
        ]
        let key = try XCTUnwrap(certificate.privateKey)
        let signature = try SignatureCrypto.sign(key, SignatureCrypto.hash(.sha256, DerWriter.setOf(attributeList)), .sha256, ec: false)
        let parameters = DerWriter.sequence([DerWriter.node(0xA2, DerWriter.node(0x04, [0x20]))])
        let digestOid = "2.16.840.1.101.3.4.2.1"
        let signer = DerWriter.sequence([
            DerWriter.integer(1),
            DerWriter.sequence([certificate.issuerName, DerWriter.integer(certificate.serialNumber)]),
            CmsBuilder.algorithmIdentifier(digestOid, withNull: true),
            DerWriter.setOf(attributeList, tag: 0xA0),
            DerWriter.sequence([DerWriter.oid(Oids.rsaPss), parameters]),
            DerWriter.octetString(signature),
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

    func test_malformedPSSParametersBreakThatSignatureAndNothingElse() throws {
        let file = try PdfSigner.sign(SignatureKit.plain(), SignatureObjects.leafRequest { $0.format = .pkcs7Detached })
        let forged = SignatureKit.splice(file) { content in (try? self.malformedPss(content)) ?? [] }
        let second = try SignatureObjects.second(forged, fieldName: "Second")

        let reports = try SignatureKit.verify(second)

        XCTAssertEqual(reports[0].verdict, .broken)
        XCTAssertEqual(reports[1].verdict, .valid)
    }

    func test_aCertificateMadeForWebServersIsNotADocumentSigner() throws {
        let server = try pki.issued("Web Server", [.digitalSignature, .keyEncipherment], "1.3.6.1.5.5.7.3.1")

        let report = try one(PdfSigner.sign(SignatureKit.plain(), by(server)))

        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.problems.contains(.untrustedSigner))
    }

    func test_aCertificateThatMayOnlySignCertificatesIsNotADocumentSigner() throws {
        let authority = try pki.issued("Key Signer", .keyCertSign)

        let report = try one(PdfSigner.sign(SignatureKit.plain(), by(authority)))

        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.problems.contains(.untrustedSigner))
    }

    func test_aMailCertificateSignsDocuments() throws {
        let mail = try pki.issued("Mail", .digitalSignature, emailProtection)

        XCTAssertEqual(try one(PdfSigner.sign(SignatureKit.plain(), by(mail))).verdict, .valid)
    }

    func test_aTimeStampAuthorityNeedsTheTimeStampingPurpose() throws {
        let plain = try pki.issued("Plain", .digitalSignature)
        let mail = try pki.issued("Mail", .digitalSignature, emailProtection)
        let both = try pki.issued("Both", .digitalSignature, emailProtection, timeStamping)

        func trusted(_ certificate: X509Certificate, _ stamp: Bool) -> Bool {
            CertificateTrust.evaluate(certificate, pki.chain, Pki.signing, pki.trusting, timestamp: stamp).trusted
        }

        XCTAssertFalse(trusted(plain, true))
        XCTAssertFalse(trusted(mail, true))
        XCTAssertTrue(trusted(both, true))
        XCTAssertTrue(trusted(pki.tsa, true))
        XCTAssertFalse(trusted(pki.tsa, false))
    }

    func test_aTimeStampFromAnAuthorityNobodyTrustsDoesNotMoveTheSigningTime() throws {
        let key = try SignatureCrypto.newRsaKey(2048)
        let subject = X509Certificate.name("CN=Own Stamps")
        let der = try CertificateBuilder.build(subject: subject, issuer: subject, publicKeyInfo: CertificateBuilder.publicKeyInfo(key),
                                               notBefore: Pki.notBefore, notAfter: Pki.notAfter, serial: CertificateBuilder.serialNumber(),
                                               extensions: [CertificateBuilder.enhancedKeyUsage([timeStamping], critical: true)], issuerKey: key)
        let own = try XCTUnwrap(X509Certificate(der))
        own.privateKey = key
        let network = SignatureObjects.network {
            $0.stampCertificate = own
            $0.stampTime = Pki.signing.adding(years: -1)!
        }
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureObjects.leafRequest {
            $0.timestamp = TimestampSettings(network, url: self.stampUrl)
            $0.level = .t
        })
        var options = VerifyOptions()
        options.trustAnchors = [pki.root]
        options.now = Pki.signing.adding(days: 5)

        let report = try one(PdfSignatureVerifier.verify(signed, options))

        XCTAssertNil(report.timestampTime)
        XCTAssertEqual(report.timeUsed, options.now)
    }

    func test_aRevocationAfterTheClaimedTimeCountsWhenNothingProvesTheTime() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        let archived = try PdfLongTermValidation.add(signed, SignatureObjects.network {
            $0.revoked = true
            $0.revokedAt = Pki.signing.adding(days: 30)!
        }, Pki.signing)
        var later = VerifyOptions()
        later.trustAnchors = [pki.root]
        later.now = Pki.signing.adding(days: 60)

        let report = try one(PdfSignatureVerifier.verify(archived, later))

        XCTAssertTrue(report.problems.contains(.certificateRevoked))
        XCTAssertNotEqual(report.verdict, .valid)
    }

    // ---- revocation data

    private func answerOf(_ network: FakeNetwork) throws -> [UInt8] {
        try XCTUnwrap(network.post(Pki.ocspUrl, "application/ocsp-request", OcspResponse.buildRequest(pki.leaf, pki.intermediate)))
    }

    private func state(_ answer: [UInt8]) throws -> RevocationState {
        try XCTUnwrap(OcspResponse.parse(answer)).about(pki.leaf, pki.intermediate).state
    }

    func test_anOcspAnswerSignedByACertificateWithoutTheOcspPurposeSaysNothing() throws {
        let colleague = try pki.issued("Colleague", .digitalSignature)
        let responder = try pki.issued("Responder", .digitalSignature, ocspSigning)

        for revoked in [false, true] {
            XCTAssertEqual(try state(answerOf(SignatureObjects.network { $0.responder = colleague; $0.revoked = revoked })), .noData)
        }
        XCTAssertEqual(try state(answerOf(SignatureObjects.network { $0.responder = responder })), .good)
        XCTAssertEqual(try state(answerOf(SignatureObjects.network { $0.responder = responder; $0.revoked = true })), .revoked)
    }

    func test_archivedRevocationDataFromALesserResponderDoesNotLiftTheLevel() throws {
        let colleague = try pki.issued("Colleague", .digitalSignature)
        let responder = try pki.issued("Responder", .digitalSignature, ocspSigning)

        let forged = try one(PdfSigner.sign(SignatureKit.plain(), archived(SignatureObjects.network { $0.responder = colleague; $0.crlDown = true })))
        let proper = try one(PdfSigner.sign(SignatureKit.plain(), archived(SignatureObjects.network { $0.responder = responder; $0.crlDown = true })))

        XCTAssertFalse(forged.revocationChecked)
        XCTAssertEqual(forged.level, .t)
        XCTAssertTrue(proper.revocationChecked)
        XCTAssertEqual(proper.level, .lt)
    }

    func test_anAnswerOlderThanTheTimeStampProvesNothingUnlessItIsStillValidThen() throws {
        let old = Pki.signing.adding(days: -30)!

        let stale = try one(PdfSigner.sign(SignatureKit.plain(), archived(SignatureObjects.network { $0.issued = old; $0.crlDown = true })))
        let covering = try one(PdfSigner.sign(SignatureKit.plain(), archived(SignatureObjects.network {
            $0.issued = old
            $0.nextUpdate = Pki.signing.adding(days: 5)
            $0.crlDown = true
        })))
        let fresh = try one(PdfSigner.sign(SignatureKit.plain(), archived(SignatureObjects.network { $0.crlDown = true })))

        XCTAssertFalse(stale.revocationChecked)
        XCTAssertTrue(covering.revocationChecked)
        XCTAssertTrue(fresh.revocationChecked)
    }

    func test_aListThatRanOutBeforeTheTimeStampProvesNothing() throws {
        let old = Pki.signing.adding(days: -30)!

        let stale = try one(PdfSigner.sign(SignatureKit.plain(), archived(SignatureObjects.network {
            $0.ocspDown = true
            $0.issued = old
            $0.nextUpdate = Pki.signing.adding(days: -20)
        })))
        let covering = try one(PdfSigner.sign(SignatureKit.plain(), archived(SignatureObjects.network {
            $0.ocspDown = true
            $0.issued = old
            $0.nextUpdate = Pki.signing.adding(days: 20)
        })))

        XCTAssertFalse(stale.revocationChecked)
        XCTAssertTrue(covering.revocationChecked)
    }

    // An IssuingDistributionPoint whose [tag] flag is true.
    private func scope(_ tag: Int) -> X509Extension {
        X509Extension(oid: "2.5.29.28", critical: true, value: DerWriter.sequence([DerWriter.node(UInt8(0x80 | tag), [0xFF])]))
    }

    private func delta() -> X509Extension {
        X509Extension(oid: "2.5.29.27", critical: true, value: DerWriter.integer(1))
    }

    func test_aListThatDoesNotCoverTheCertificateDoesNotMakeItGood() throws {
        for kind in ["authorities", "attributes", "delta", "whole"] {
            let extension_: X509Extension?
            switch kind {
            case "authorities": extension_ = scope(2)
            case "attributes": extension_ = scope(5)
            case "delta": extension_ = delta()
            default: extension_ = nil
            }
            let network = SignatureObjects.network { $0.ocspDown = true; $0.crlExtension = extension_ }

            let report = try one(PdfSigner.sign(SignatureKit.plain(), archived(network)))

            XCTAssertEqual(report.revocationChecked, kind == "whole", kind)
            XCTAssertEqual(report.level, kind == "whole" ? .lt : .t, kind)
        }
    }

    func test_aListForEndEntitiesOnlyCoversTheSigner() throws {
        let network = SignatureObjects.network { $0.ocspDown = true; $0.crlExtension = self.scope(1) }

        XCTAssertTrue(try one(PdfSigner.sign(SignatureKit.plain(), archived(network))).revocationChecked)
    }

    // ---- signing into a file with rules

    func test_aDocumentTimeStampAndValidationDataStillFollowACertificationWithoutChanges() throws {
        let network = FakeNetwork()
        let certified = try SignatureTestHelpers.certified(.noChanges)

        let stamped = try PdfSigner.addDocumentTimestamp(certified, TimestampSettings(network, url: stampUrl), Pki.signing.adding(days: 1)!)
        let archived = try PdfLongTermValidation.add(stamped, network, Pki.signing.adding(days: 1)!)

        for report in try SignatureKit.verify(archived) { XCTAssertEqual(report.verdict, .valid) }
    }

    func test_aFieldAnEarlierSignatureLockedIsNotSigned() throws {
        let empty = try PdfDocument.open(SignatureKit.plain())
        _ = try PdfForm.read(empty).addField(FieldSpec(.signature, "Later", 0, PdfRect(10, 10, 100, 40)))
        let prepared = try empty.saveIncremental()
        let locked = try PdfSigner.sign(prepared, SignatureObjects.leafRequest { $0.lock = FieldLock(.include, ["Later"]) })
        let open = try PdfSigner.sign(prepared, SignatureObjects.leafRequest { $0.lock = FieldLock(.include, ["Other"]) })

        XCTAssertThrowsError(try PdfSigner.sign(locked, SignatureObjects.request(pki.leafEc, Pki.signing) { $0.fieldName = "Later" })) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, SignatureText.fieldLocked)
        }
        let again = try PdfSigner.sign(open, SignatureObjects.request(pki.leafEc, Pki.signing) { $0.fieldName = "Later" })
        for report in try SignatureKit.verify(again) { XCTAssertEqual(report.verdict, .valid) }
    }

    // ---- digital ids

    func test_anImportedIdKeepsItsKeyInMemoryAndTheFileIsProtectedWithAES() throws {
        let id = try PdfDigitalId.create("Ada Lovelace", nil, DateTimeOffset(2026, 3, 1, 0, 0, 0), keyBits: 2048)

        XCTAssertEqual(try one(PdfSigner.sign(SignatureKit.plain(), PdfSignRequest(id, Pki.signing))).verdict, .validButUntrusted)
    }

    // ---- appearance

    func test_theAppearanceOfAVisibleSignatureStandsUprightOnATurnedPage() throws {
        for rotate in [0, 90, 180, 270] {
            let document = try PdfDocument.open(SignatureKit.plain())
            document.pages[0].dictionary["Rotate"] = PdfNumber(rotate)
            let turned = try document.saveIncremental()
            let rect = PdfRect(20, 20, 200, 60)

            let signed = try PdfSigner.sign(turned, SignatureObjects.leafRequest { $0.rect = rect })

            let reopened = try PdfDocument.open(signed)
            let widget = try SignatureObjects.signatureField(reopened).widgets[0].dictionary
            let form = try XCTUnwrap(reopened.resolve(reopened.dict(widget, "AP")?["N"]) as? PdfStream)
            let box = try XCTUnwrap(reopened.array(form.dictionary, "BBox")).items.map { ($0 as? PdfNumber)?.value ?? .nan }
            let m = try XCTUnwrap(reopened.array(form.dictionary, "Matrix")).items.map { ($0 as? PdfNumber)?.value ?? .nan }
            let sideways = rotate == 90 || rotate == 270
            XCTAssertEqual(box[2], sideways ? rect.height : rect.width, "\(rotate)")
            XCTAssertEqual(box[3], sideways ? rect.width : rect.height, "\(rotate)")

            // The form's right-pointing axis, turned the way the page is turned, points right again.
            var (x, y) = (m[0], m[1])
            for _ in 0..<(rotate / 90) { (x, y) = (y, -x) }
            XCTAssertEqual(x.rounded(), 1, "\(rotate)")
            XCTAssertEqual(y.rounded(), 0, "\(rotate)")
            XCTAssertEqual(abs(m[0] * box[2] + m[2] * box[3]), rect.width, "\(rotate)")
            XCTAssertEqual(abs(m[1] * box[2] + m[3] * box[3]), rect.height, "\(rotate)")
            XCTAssertEqual(try one(signed).verdict, .valid, "\(rotate)")
            XCTAssertEqual(reopened.pages.count, 2, "\(rotate)")
        }
    }
}
#endif
