#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/EditSessionCertificateTests.cs: the same cases.

final class EditSessionCertificateTests: XCTestCase {
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        folder = try temporaryFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func test_recipientEditsAndSavesAnEncryptedFile() throws {
        let path = folder.appendingPathComponent("sealed.pdf").path
        try Data(PublicKeyFiles.seal(PublicKeyFiles.alice)).write(to: URL(fileURLWithPath: path))
        let session = try PdfEditSession.open(path: path, certificate: PublicKeyFiles.alice)

        session.document.info?["Title"] = PdfString(bytes: Latin1.bytes("Edited"), isHex: false)
        XCTAssertTrue(try session.commit("title"))
        XCTAssertTrue(try session.undo())
        XCTAssertTrue(try session.redo())
        try session.save(path)

        let again = try PdfDocument.open(path: path, certificate: PublicKeyFiles.alice)
        XCTAssertEqual(again.security?.isPublicKey, true)
        XCTAssertEqual(SaveFixtures.title(again), "Edited")
    }

    func test_compactSaveKeepsTheRecipients() throws {
        let path = folder.appendingPathComponent("compact.pdf").path
        let session = try PdfEditSession.open(PublicKeyFiles.seal(PublicKeyFiles.alice), certificate: PublicKeyFiles.alice)

        try session.saveCompact(path)

        let again = try PdfDocument.open(path: path, certificate: PublicKeyFiles.alice)
        XCTAssertEqual(again.security?.isPublicKey, true)
    }

    func test_saverReadsBackWithTheCertificate() throws {
        let path = folder.appendingPathComponent("saver.pdf").path
        let sealedFile = try PublicKeyFiles.seal(PublicKeyFiles.alice)

        assertReadFails(try PdfFileSaver.save(path, sealedFile))
        try PdfFileSaver.save(path, sealedFile, certificate: PublicKeyFiles.alice)

        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), sealedFile)
    }
}
#endif
