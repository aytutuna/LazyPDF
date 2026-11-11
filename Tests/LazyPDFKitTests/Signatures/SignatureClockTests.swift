#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureClockTests.cs: the same cases.

final class SignatureClockTests: XCTestCase {
    private let pki = Pki.instance

    private func options(now: DateTimeOffset) -> VerifyOptions {
        var options = VerifyOptions()
        options.trustAnchors = [pki.root]
        options.now = now
        return options
    }

    func test_withoutATimeStampACertificateThatHasSinceExpiredIsJudgedAtTheClaimedTime() throws {
        var request = PdfSignRequest(pki.shortLived, Pki.signing)
        request.chain = pki.chain
        let signed = try PdfSigner.sign(SignatureKit.plain(), request)
        let now = try PdfSignatureVerifier.verify(signed, options(now: Pki.signing.adding(days: 1)!))
        XCTAssertEqual(now.count, 1)
        XCTAssertEqual(now.first?.verdict, .valid)

        let reports = try PdfSignatureVerifier.verify(signed, options(now: Pki.expiry.adding(days: 10)!))
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertTrue(report.problems.contains(.certificateExpired))
        XCTAssertFalse(report.problems.contains(.certificateNotValid))
        XCTAssertEqual(report.timeUsed, Pki.signing)
        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.sentence.hasSuffix("The certificate has expired since."))
    }

    func test_aClaimedTimeBeforeTheCertificateBeganIsNotValid() throws {
        var request = PdfSignRequest(pki.shortLived, Pki.notBefore.adding(days: -30)!)
        request.chain = pki.chain
        let signed = try PdfSigner.sign(SignatureKit.plain(), request)

        let reports = try PdfSignatureVerifier.verify(signed, options(now: Pki.expiry.adding(days: 10)!))

        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertTrue(report.problems.contains(.certificateNotValid))
        XCTAssertFalse(report.problems.contains(.certificateExpired))
    }

    func test_aStampedSignatureIsNotFlaggedForACertificateThatHasSinceExpired() throws {
        let network = FakeNetwork()
        network.stampTime = Pki.signing.adding(minutes: 1)!
        var request = PdfSignRequest(pki.shortLived, Pki.signing)
        request.chain = pki.chain
        request.timestamp = TimestampSettings(network, url: "http://tsa.test/")

        let reports = try PdfSignatureVerifier.verify(PdfSigner.sign(SignatureKit.plain(), request), options(now: Pki.expiry.adding(days: 10)!))

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.verdict, .valid)
        XCTAssertEqual(reports.first?.problems, [])
    }

    func test_aRevocationBetweenTheClaimAndNowStillCounts() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        let archived = try PdfLongTermValidation.add(signed, SignatureObjects.network {
            $0.revoked = true
            $0.revokedAt = Pki.signing.adding(days: 30)!
        }, Pki.signing)

        let reports = try PdfSignatureVerifier.verify(archived, options(now: Pki.signing.adding(days: 60)!))

        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(try XCTUnwrap(reports.first).problems.contains(.certificateRevoked))
        XCTAssertEqual(reports.first?.timeUsed, Pki.signing)
    }
}
#endif