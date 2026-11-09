#if canImport(Security)
import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/sign/SigningFailureTests.cs: a signing that fails or is cancelled leaves the file as it
// was, and the panel only claims what the servers gave. The transport cannot throw here, so a cancelled run is a CancelToken
// that is cancelled and a transport that answers nobody.

final class SigningFailureTests: XCTestCase {
    private func stamped(_ certificate: X509Certificate) -> SignChoices {
        var choices = SigningKit.plain(certificate)
        choices.timestampUrl = "https://tsa.example/stamp"
        return choices
    }

    private func reports(_ session: PdfEditSession) throws -> [SignatureReport] {
        try PdfSignatureVerifier.verify(session.current, SigningKit.options())
    }

    func test_aTimeStampThatFailsLeavesNoSignatureBehind() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())

        XCTAssertThrowsError(try CertificateSigning.sign(session, stamped(ada), SilentServer(), FakeFonts(), SigningKit.now)) {
            XCTAssertTrue($0 is InvalidOperationException)
        }

        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.document.isSigned)
        XCTAssertTrue(PdfForm.read(session.document).fields.isEmpty)
    }

    func test_signingAgainAfterAFailureMakesOneGoodSignature() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        XCTAssertThrowsError(try CertificateSigning.sign(session, stamped(ada), SilentServer(), FakeFonts(), SigningKit.now))

        try CertificateSigning.sign(session, SigningKit.plain(ada), SilentServer(), FakeFonts(), SigningKit.now)

        let found = try reports(session)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].verdict, .validButUntrusted)
    }

    func test_anEmptyFieldIsStillEmptyAfterAFailure() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        _ = try PdfForm.read(session.document).addField(FieldSpec(.signature, "Approval", 0, PdfRect(72, 100, 200, 150)))
        try session.commit("Field")
        var choices = stamped(ada)
        choices.field = "Approval"

        XCTAssertThrowsError(try CertificateSigning.sign(session, choices, SilentServer(), FakeFonts(), SigningKit.now))

        XCTAssertEqual(CertificateSigning.emptyFields(session.document), ["Approval"])
    }

    func test_aCancelledSigningLeavesTheFileAsItWas() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        let token = CancelToken()
        token.cancel()

        XCTAssertThrowsError(try CertificateSigning.sign(session, stamped(ada), CancellableTransport(SilentServer(), token), FakeFonts(), SigningKit.now, token: token)) {
            XCTAssertTrue($0 is CancellationError)
        }

        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.document.isSigned)
    }

    func test_aSigningCancelledWhileItRunsIsTakenBack() throws {
        let ada = try SigningKit.ada()
        let session = try PdfEditSession.open(Pdfs.text())
        let token = CancelToken()

        XCTAssertThrowsError(try CertificateSigning.sign(session, stamped(ada), CancelsOnRequest(token), FakeFonts(), SigningKit.now, token: token)) {
            XCTAssertTrue($0 is CancellationError)
        }

        XCTAssertFalse(session.document.isSigned)
        XCTAssertFalse(session.canUndo)
    }

    func test_aCancelledValidationLeavesNoPartOfItPending() throws {
        let session = try SigningKit.signedByGrace()
        let length = session.current.count
        let token = CancelToken()

        XCTAssertThrowsError(try CertificateSigning.addValidation(session, CancelsOnRequest(token), SigningKit.now, token: token)) {
            XCTAssertTrue($0 is CancellationError)
        }

        XCTAssertEqual(session.current.count, length)
        XCTAssertFalse(session.document.hasChanges)
    }

    func test_validationWithNoServerAddsCertificatesButIsNotProofOfRevocation() throws {
        let session = try SigningKit.signedByGrace()
        let length = session.current.count

        try CertificateSigning.addValidation(session, SilentServer(), SigningKit.now)

        XCTAssertGreaterThan(session.current.count, length)
        XCTAssertFalse(try CertificateSigning.revocationCovered(session.current, SigningKit.options()))
    }

    func test_aFileWithoutSignaturesIsNotCovered() throws {
        XCTAssertTrue(try CertificateSigning.revocationCovered(Pdfs.text(), SigningKit.options()))
    }

    func test_onlyAWebAddressIsATimeStampServer() {
        XCTAssertTrue(CertificateSigning.isWebAddress(" https://timestamp.example/tsa "))
        XCTAssertTrue(CertificateSigning.isWebAddress("http://timestamp.example"))
        XCTAssertFalse(CertificateSigning.isWebAddress("timestamp.example"))
        XCTAssertFalse(CertificateSigning.isWebAddress("http://"))
        XCTAssertFalse(CertificateSigning.isWebAddress("ftp://timestamp.example"))
        XCTAssertFalse(CertificateSigning.isWebAddress(""))
    }

    func test_aFileThatAllowsNothingCannotBeSigned() throws {
        let locked = try PdfDocument.open(Pdfs.restricted(.print), password: "")
        let form = try PdfDocument.open(Pdfs.restricted(.fillForms), password: "")
        let owner = try PdfDocument.open(Pdfs.restricted(.print), password: "owner")

        XCTAssertNotNil(CertificateSigning.refusal(locked, newField: false))
        XCTAssertNotNil(CertificateSigning.refusal(locked, newField: true))
        XCTAssertNil(CertificateSigning.refusal(form, newField: false))
        XCTAssertNotNil(CertificateSigning.refusal(form, newField: true))
        XCTAssertNil(CertificateSigning.refusal(owner, newField: true))
        XCTAssertNil(CertificateSigning.refusal(try PdfDocument.open(Pdfs.text()), newField: true))
    }

    func test_aCancelWhileTheServerIsAnsweringStopsTheSigning() {
        let token = CancelToken()
        final class CancelsOnPost: SignatureTransport {
            let token: CancelToken

            init(_ token: CancelToken) {
                self.token = token
            }

            func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
                token.cancel()
                return [1]
            }

            func get(_ url: String) -> [UInt8]? { nil }
        }

        XCTAssertNil(CancellableTransport(CancelsOnPost(token), token).post("http://x", "a/b", []))
    }
}
#endif
