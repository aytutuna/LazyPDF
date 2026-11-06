import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/CertificateFlowTests.cs: a file encrypted for recipients asks for a certificate, not a
// password. The keychain is a stand-in that knows one identity, since opening with a real key needs Security. Not ported:
// TheEngineDecryptsAPublicKeyFileForTheSystemToDraw, which is the page renderer's test.

@MainActor
final class CertificateFlowTests: XCTestCase {
    private func recipientsFile(_ f: ViewModelFixture) -> URL {
        f.dir.file("secret.pdf", Pdfs.forRecipients())
    }

    func test_aFileForRecipientsAsksForACertificate() async {
        let f = ViewModelFixture(self)

        await f.vm.open(recipientsFile(f))

        let request = f.vm.passwordRequest
        XCTAssertEqual(request?.needsCertificate, true)
        XCTAssertEqual(request?.certificates, [FakeKeys.alice])
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_theRightCertificateOpensItAndItIsDrawn() async {
        let f = ViewModelFixture(self)
        await f.vm.open(recipientsFile(f))

        await f.vm.submitCertificate(FakeKeys.alice)

        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertEqual(f.vm.activeDocument?.title, "secret.pdf")
        XCTAssertEqual(f.vm.activeDocument?.certificate, FakeKeys.alice)
        XCTAssertEqual(f.renderers.first?.loads, 1)
    }

    func test_anotherCertificateIsSaidToBeWrongAndAsksAgain() async {
        let f = ViewModelFixture(self)
        await f.vm.open(recipientsFile(f))

        await f.vm.submitCertificate(FakeKeys.mallory)

        let request = f.vm.passwordRequest
        XCTAssertEqual(request?.needsCertificate, true)
        XCTAssertEqual(request?.problem, "That certificate does not open this file.")
        XCTAssertEqual(request?.attempts, 1)
    }
}
