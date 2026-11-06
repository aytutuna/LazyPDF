#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureClockTests.cs: the same case.

final class SignatureClockTests: XCTestCase {
    private let pki = Pki.instance

    func test_withoutATimeStampACertificateThatHasSinceExpiredIsNotTrusted() throws {
        var request = PdfSignRequest(pki.shortLived, Pki.signing)
        request.chain = pki.chain
        let signed = try PdfSigner.sign(SignatureKit.plain(), request)
        var options = VerifyOptions()
        options.trustAnchors = [pki.root]
        options.now = Pki.signing.adding(days: 1)
        let now = try PdfSignatureVerifier.verify(signed, options)
        XCTAssertEqual(now.count, 1)
        XCTAssertEqual(now.first?.verdict, .valid)

        var later = VerifyOptions()
        later.trustAnchors = [pki.root]
        later.now = Pki.expiry.adding(days: 10)
        let reports = try PdfSignatureVerifier.verify(signed, later)
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(try XCTUnwrap(reports.first).problems.contains(.certificateNotValid))
    }
}
#endif
