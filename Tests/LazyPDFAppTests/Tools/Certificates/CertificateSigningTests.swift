#if canImport(Security)
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/sign/CertificateSigningTests.cs: signing with what the panel collects, through the real
// signer and verifier. The cancel test of the Windows file is in CancelTests below: the transport here answers nobody once the
// token is cancelled, since the engine's transport cannot throw.

final class CertificateSigningTests: XCTestCase {
    private func request(_ choices: SignChoices) -> PdfSignRequest {
        CertificateSigning.request(choices, SilentServer(), FakeFonts(), SigningKit.now)
    }

    private func only(_ session: PdfEditSession, trusting: [X509Certificate] = []) throws -> SignatureReport {
        let reports = try PdfSignatureVerifier.verify(session.current, SigningKit.options(trusting: trusting))
        XCTAssertEqual(reports.count, 1)
        return try XCTUnwrap(reports.first)
    }

    func test_anInvisibleSignatureIsMadeByTheCertificate() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())

        try PdfSigner.sign(session, request(SigningKit.plain(ada)))

        let report = try only(session)
        XCTAssertEqual(report.signerName, "Ada Lovelace")
        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(session.canUndo)
    }

    func test_addingTheCertificateToTheTrustedOnesMakesItValid() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        try PdfSigner.sign(session, request(SigningKit.plain(ada)))

        XCTAssertEqual(try only(session, trusting: [ada]).verdict, .valid)
    }

    func test_reasonAndPlaceAreSignedAndBlankOnesLeftOut() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        var choices = SigningKit.plain(ada)
        choices.reason = "  Approved "
        choices.location = "   "
        try PdfSigner.sign(session, request(choices))

        let report = try only(session)

        XCTAssertEqual(report.reason, "Approved")
        XCTAssertNil(report.location)
    }

    func test_aBoxMakesAVisibleSignatureOnThatPage() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text(2))
        let box = PdfRect(72, 600, 272, 660)
        var choices = SigningKit.plain(ada)
        choices.page = 1
        choices.rect = box

        try PdfSigner.sign(session, request(choices))

        let widgets = PdfAnnotations.readAll(session.document).filter { $0.type == .widget }
        XCTAssertEqual(widgets.count, 1)
        XCTAssertEqual(widgets[0].pageIndex, 1)
        XCTAssertEqual(widgets[0].rect, box)
        XCTAssertEqual(try only(session).verdict, .validButUntrusted)
    }

    func test_anEmptyFieldOfTheFileIsSignedWhereItStands() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        _ = try PdfForm.read(session.document).addField(FieldSpec(.signature, "Approval", 0, PdfRect(72, 100, 200, 150)))
        try session.commit("Field")
        XCTAssertEqual(CertificateSigning.emptyFields(session.document), ["Approval"])
        var choices = SigningKit.plain(ada)
        choices.field = "Approval"

        try PdfSigner.sign(session, request(choices))

        XCTAssertEqual(try only(session).fieldName, "Approval")
        XCTAssertTrue(CertificateSigning.emptyFields(session.document).isEmpty)
    }

    func test_theFirstSignatureCanCertifyTheFile() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        var choices = SigningKit.plain(ada)
        choices.certify = .formFill

        try PdfSigner.sign(session, request(choices))

        let report = try only(session)
        XCTAssertEqual(report.kind, .certification)
        XCTAssertEqual(report.certification, .formFill)
    }

    func test_aSecondSignatureCannotCertify() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        try PdfSigner.sign(session, request(SigningKit.plain(ada)))
        var second = SigningKit.plain(ada)
        second.certify = .noChanges

        XCTAssertThrowsError(try PdfSigner.sign(session, request(second))) {
            XCTAssertEqual(($0 as? InvalidOperationException)?.message, SignatureText.notCertifiable)
        }
    }

    func test_addressAndLongTermChooseTheLevel() throws {
        let ada = try SigningKit.ada()
        var stamped = SigningKit.plain(ada)
        stamped.timestampUrl = "http://tsa.example/stamp"
        var longTerm = stamped
        longTerm.longTerm = true
        var blank = SigningKit.plain(ada)
        blank.timestampUrl = ""
        blank.longTerm = true

        let none = request(SigningKit.plain(ada))
        XCTAssertEqual(none.level, .b)
        XCTAssertNil(none.timestamp)
        XCTAssertEqual(request(stamped).level, .t)
        XCTAssertEqual(request(stamped).timestamp?.url, "http://tsa.example/stamp")
        XCTAssertEqual(request(longTerm).level, .lt)
        XCTAssertEqual(request(blank).level, .b)
    }

    func test_aTimeStampServerThatAnswersNothingIsSaidSo() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        var choices = SigningKit.plain(ada)
        choices.timestampUrl = "http://tsa.example/stamp"

        XCTAssertThrowsError(try PdfSigner.sign(session, request(choices))) {
            XCTAssertEqual(($0 as? InvalidOperationException)?.message, SignatureText.noTimestamp)
        }
        XCTAssertFalse(session.canUndo)
    }

    func test_aCertificateWithoutItsKeyIsRefused() throws {
        let ada = try SigningKit.ada()
        let publicOnly = try XCTUnwrap(X509Certificate(ada.rawData))
        let session = try PdfEditSession.open(Pdfs.text())

        XCTAssertThrowsError(try PdfSigner.sign(session, request(SigningKit.plain(publicOnly)))) {
            XCTAssertEqual(($0 as? InvalidOperationException)?.message, SignatureText.noPrivateKey)
        }
    }

    func test_cancelStopsTheNextRequestToAServer() {
        final class Counting: SignatureTransport {
            var calls = 0
            func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
                calls += 1
                return [1]
            }

            func get(_ url: String) -> [UInt8]? {
                calls += 1
                return [1]
            }
        }
        let inner = Counting()
        let token = CancelToken()
        let transport = CancellableTransport(inner, token)
        XCTAssertEqual(transport.get("http://x"), [1])

        token.cancel()

        XCTAssertNil(transport.post("http://x", "a/b", []))
        XCTAssertNil(transport.get("http://x"))
        XCTAssertEqual(inner.calls, 1)
    }

    func test_aFileWithoutSignaturesTakesNoValidationData() throws {
        let session = try PdfEditSession.open(Pdfs.text())

        XCTAssertThrowsError(try PdfLongTermValidation.add(session, SilentServer(), SigningKit.now)) { XCTAssertTrue($0 is InvalidOperationException) }
    }
}
#endif
