#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/LongTermValidationTests.cs: the same cases. The C# also opens the
// first file with PdfPig and counts its pages; that has no twin, and the page count is read with PdfDocument instead.

final class LongTermValidationTests: XCTestCase {
    private let pki = Pki.instance
    private let tsa = "http://tsa.test/"

    private func request(_ network: FakeNetwork, _ level: PadesLevel) -> PdfSignRequest {
        var request = SignatureKit.request(pki)
        request.timestamp = TimestampSettings(network, url: tsa)
        request.level = level
        return request
    }

    private func single(_ reports: [SignatureReport], line: UInt = #line) throws -> SignatureReport {
        XCTAssertEqual(reports.count, 1, line: line)
        return try XCTUnwrap(reports.first, line: line)
    }

    private func dss(_ file: [UInt8]) throws -> (certs: Int, ocsps: Int, crls: Int, vri: PdfDictionary) {
        let document = try PdfDocument.open(file)
        let dss = try XCTUnwrap(document.dict(document.catalog, "DSS"))
        return (document.array(dss, "Certs")?.items.count ?? 0, document.array(dss, "OCSPs")?.items.count ?? 0,
                document.array(dss, "CRLs")?.items.count ?? 0, try XCTUnwrap(document.dict(dss, "VRI")))
    }

    func test_b_LT_carriesTheChainAndItsRevocationDataInTheFile() throws {
        let network = FakeNetwork()
        let signed = try PdfSigner.sign(SignatureKit.plain(), request(network, .lt))

        let report = try single(SignatureKit.verify(signed))
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertEqual(report.level, .lt)
        XCTAssertTrue(report.revocationChecked)

        let found = try dss(signed)
        XCTAssertTrue(found.certs >= 4, "leaf, intermediate, root and the time stamp authority")
        XCTAssertEqual(found.ocsps, 1)
        XCTAssertEqual(found.crls, 1)
        let key = Sha1.hash(SignatureKit.parts(signed).cms).map { String(format: "%02X", $0) }.joined()
        let document = try PdfDocument.open(signed)
        let entry = try XCTUnwrap(document.resolve(found.vri[key]) as? PdfDictionary)
        XCTAssertEqual((entry["Type"] as? PdfName)?.value, "VRI")
        XCTAssertNotNil(entry["Cert"])
        XCTAssertNotNil(entry["OCSP"])
        XCTAssertTrue(network.requests.contains(Pki.ocspUrl))
        XCTAssertTrue((network.requests + [Pki.issuerUrl]).contains(Pki.issuerUrl))
        XCTAssertEqual(document.pages.count, 2)
    }

    func test_theValidationDataAloneIsEnoughToCheckRevocationOffline() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), request(FakeNetwork(), .lt))

        // The signature's own certificates are removed from nothing here: revocation comes from the /DSS, not a network.
        let report = try single(PdfSignatureVerifier.verify(signed, pki.trusting))

        XCTAssertTrue(report.revocationChecked)
        XCTAssertTrue(report.problems.isEmpty)
    }

    func test_aCertificateRevokedBeforeSigningMakesTheSignatureUntrusted() throws {
        let network = FakeNetwork()
        network.revoked = true
        let signed = try PdfSigner.sign(SignatureKit.plain(), request(network, .lt))

        let report = try single(SignatureKit.verify(signed))

        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.problems.contains(.certificateRevoked))
        XCTAssertFalse(report.revocationChecked)
    }

    func test_aRevocationAfterSigningDoesNotUndoTheSignature() throws {
        let network = FakeNetwork()
        network.revoked = true
        network.revokedAt = try XCTUnwrap(Pki.signing.adding(days: 30))
        let signed = try PdfSigner.sign(SignatureKit.plain(), request(network, .lt))

        XCTAssertEqual(try single(SignatureKit.verify(signed)).verdict, .valid)
    }

    func test_aCrlStandsInWhenTheOcspResponderIsDown() throws {
        let network = FakeNetwork()
        network.ocspDown = true
        let signed = try PdfSigner.sign(SignatureKit.plain(), request(network, .lt))

        let found = try dss(signed)
        XCTAssertEqual(found.ocsps, 0)
        XCTAssertEqual(found.crls, 2)
        XCTAssertTrue(try single(SignatureKit.verify(signed)).revocationChecked)
    }

    func test_aRevokedCertificateIsFoundInACrlToo() throws {
        let network = FakeNetwork()
        network.ocspDown = true
        network.revoked = true
        let signed = try PdfSigner.sign(SignatureKit.plain(), request(network, .lt))

        XCTAssertTrue(try single(SignatureKit.verify(signed)).problems.contains(.certificateRevoked))
    }

    func test_nothingToAskLeavesTheCertificateWithoutDataAndTheLevelAtT() throws {
        let network = FakeNetwork()
        network.ocspDown = true
        network.crlDown = true
        let signed = try PdfSigner.sign(SignatureKit.plain(), request(network, .lt))

        let report = try single(SignatureKit.verify(signed))
        XCTAssertEqual(report.level, .t)
        XCTAssertFalse(report.revocationChecked)
        XCTAssertEqual(report.verdict, .valid)
    }

    func test_b_LTA_endsWithADocumentTimeStampOverEverything() throws {
        let network = FakeNetwork()
        network.stampTime = try XCTUnwrap(Pki.signing.adding(minutes: 5))
        let signed = try PdfSigner.sign(SignatureKit.plain(), request(network, .lta))

        let reports = try SignatureKit.verify(signed)

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].level, .lta)
        XCTAssertEqual(reports[0].verdict, .valid)
        XCTAssertEqual(reports[1].kind, .documentTimestamp)
        XCTAssertEqual(reports[1].subFilter, "ETSI.RFC3161")
        XCTAssertEqual(reports[1].verdict, .valid)
        XCTAssertEqual(reports[1].timestampTime, Pki.signing.adding(minutes: 5))
        XCTAssertTrue(reports[1].coversWholeFile)
        XCTAssertEqual(reports.map { $0.fieldName }, ["Signature1", "Timestamp1"])
        XCTAssertEqual(reports[1].sentence, "Time stamped on 10 Mar 2026. Not changed since.")
        XCTAssertTrue(reports[0].changes.changes.allSatisfy { $0.allowed })
        XCTAssertTrue(reports[0].changes.changes.contains { $0.kind == .validationData })
        XCTAssertTrue(reports[0].changes.changes.contains { $0.kind == .signature })
    }

    func test_aDocumentTimeStampCanBeAddedToAnyFileAndAChangeUnderItBreaksIt() throws {
        let network = FakeNetwork()
        let stamped = try PdfSigner.addDocumentTimestamp(SignatureKit.plain(), TimestampSettings(network, url: tsa), Pki.signing)

        let report = try single(SignatureKit.verify(stamped))
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertNil(report.signerName)
        XCTAssertEqual(try PdfDocument.open(stamped).pages.count, 2)

        XCTAssertEqual(try single(SignatureKit.verify(TestPdf.replace(stamped, "Contract page 1", "Contract page 7"))).verdict, .broken)
        let late = try SignatureTestHelpers.edit(stamped) { d in
            d.stream(d.pages[0].dictionary, "Contents")?.data = TestPdf.latin("BT ET")
        }
        XCTAssertEqual(try single(SignatureKit.verify(late)).verdict, .changedAfterSigning)
    }

    func test_aDocumentTimeStampNeedsAServerAndAPage() throws {
        _ = SignatureExtraKit.invalidOperation(try PdfSigner.addDocumentTimestamp(SignatureKit.plain(), TimestampSettings(FakeNetwork()), Pki.signing))
        let down = FakeNetwork()
        down.stampDown = true
        _ = SignatureExtraKit.invalidOperation(try PdfSigner.addDocumentTimestamp(SignatureKit.plain(), TimestampSettings(down, url: tsa), Pki.signing))
    }

    func test_validationDataMayBeAddedToASignedFileLaterAndOnlyOnce() throws {
        let network = FakeNetwork()
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        XCTAssertFalse(try single(SignatureKit.verify(signed)).revocationChecked)

        let withData = try PdfLongTermValidation.add(signed, network, try XCTUnwrap(Pki.signing.adding(days: 1)))

        XCTAssertTrue(withData.count > signed.count)
        XCTAssertEqual(Array(withData[0..<signed.count]), signed)
        let report = try single(SignatureKit.verify(withData))
        XCTAssertTrue(report.revocationChecked)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertEqual(try PdfLongTermValidation.add(withData, network, try XCTUnwrap(Pki.signing.adding(days: 2))), withData)
    }

    func test_validationDataIsAllowedAfterACertificationThatAllowsNoChanges() throws {
        let certified = try SignatureTestHelpers.certified(.noChanges)
        let ltv = try PdfLongTermValidation.add(certified, FakeNetwork(), try XCTUnwrap(Pki.signing.adding(days: 1)))
        let stamped = try PdfSigner.addDocumentTimestamp(ltv, TimestampSettings(FakeNetwork(), url: tsa), Pki.signing)

        let report = try SignatureKit.verify(stamped)[0]

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertEqual(report.kind, .certification)
        XCTAssertTrue(report.changes.changes.allSatisfy { $0.allowed })
    }

    func test_theServersValidationDataWouldAskAreListedWithoutAsking() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))

        let servers = try PdfLongTermValidation.servers(signed)

        XCTAssertEqual(servers, [
            ValidationServer(kind: .ocsp, url: Pki.ocspUrl, host: "ocsp.test"),
            ValidationServer(kind: .crl, url: Pki.crlUrl, host: "crl.test"),
            ValidationServer(kind: .crl, url: Pki.rootCrlUrl, host: "crl.test"),
        ])
        XCTAssertEqual(try PdfLongTermValidation.servers(try PdfEditSession.open(signed)), servers)
    }

    func test_aChainThatStopsShortOfARootListsTheTopCertificatesOwnLinksToo() throws {
        var request = SignatureKit.request(pki)
        request.chain = []
        let signed = try PdfSigner.sign(SignatureKit.plain(), request)

        let servers = try PdfLongTermValidation.servers(signed)

        XCTAssertEqual(servers, [
            ValidationServer(kind: .caIssuers, url: Pki.issuerUrl, host: "ca.test"),
            ValidationServer(kind: .ocsp, url: Pki.ocspUrl, host: "ocsp.test"),
            ValidationServer(kind: .crl, url: Pki.crlUrl, host: "crl.test"),
        ])
    }

    func test_aFileWithoutSignaturesHasNoServersToList() {
        let message = SignatureExtraKit.invalidOperation(try PdfLongTermValidation.servers(SignatureKit.plain()))
        XCTAssertEqual(message, SignatureText.notSigned)
    }

    func test_aFileWithoutSignaturesHasNothingToAddDataTo() {
        let message = SignatureExtraKit.invalidOperation(try PdfLongTermValidation.add(SignatureKit.plain(), FakeNetwork(), Pki.signing))
        XCTAssertEqual(message, SignatureText.notSigned)
    }

    func test_aSessionGetsOneStepForEachPartAndUndoGoesBackThroughThem() throws {
        let session = try PdfEditSession.open(SignatureKit.plain())
        try PdfSigner.sign(session, request(FakeNetwork(), .lta))

        XCTAssertEqual(session.undoLabel, "Time stamp")
        XCTAssertEqual(try PdfSignatureVerifier.verify(session, pki.trusting).count, 2)
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(session.undoLabel, "Validation data")
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(session.undoLabel, "Sign")
        XCTAssertEqual(try single(PdfSignatureVerifier.verify(session, pki.trusting)).level, .t)
    }

    func test_levelsWithoutATimeStampServerAreRefused() {
        var request = SignatureKit.request(pki)
        request.level = .lt
        _ = SignatureExtraKit.invalidOperation(try PdfSigner.sign(SignatureKit.plain(), request))
    }
}
#endif
