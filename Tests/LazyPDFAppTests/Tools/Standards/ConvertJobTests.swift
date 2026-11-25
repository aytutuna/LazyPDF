import XCTest
import LazyPDFKit
#if canImport(Security)
import Security
#endif
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/standards/ConvertJobTests.cs: what the PDF/A panel takes from a tab, and the words it
// uses for the result. OpenCopy lives in Tools/Common and is tested here with the job, as the Windows file does.

@MainActor
final class ConvertJobTests: XCTestCase {
    private func tabOf(_ bytes: [UInt8], title: String = "Quarterly report.pdf", password: String? = nil,
                       certificate: CertificateChoice? = nil) throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(bytes, password: password), renderer: FakeRenderer(), url: nil, title: title,
                    password: password, certificate: certificate)
    }

    private func protectedFile() throws -> [UInt8] {
        let document = try PdfDocument.open(Pdfs.text())
        let security = PdfSecurity.create(userPassword: "open", ownerPassword: "owner", permissions: [.print, .modify], strength: .aes256,
                                          firstId: [UInt8](repeating: 5, count: 16))
        return try document.saveRewrite(PdfSaveOptions(security: security))
    }

    func test_aTabIsConvertedOffTheMainActorFromTheBytesItHadWhenTheJobWasMade() async throws {
        let tab = try tabOf(Pdfs.text())
        let job = ConvertJob(tab, SecurityHost())
        try Pdfs.retitle(tab.session, "Changed after")
        try tab.commit("Title")

        let made = try await Task.detached { try job.run(.a2b, FakeFonts()) }.value

        let bytes = try XCTUnwrap(made.bytes)
        XCTAssertNotEqual(DocumentMetadata.read(try PdfDocument.open(bytes)).title, "Changed after")
    }

    func test_aFileOpenedWithTheOwnerPasswordIsConvertedWithIt() async throws {
        let tab = try tabOf(protectedFile(), password: "owner")

        let made = try ConvertJob(tab, SecurityHost()).run(.a2b, FakeFonts())

        XCTAssertFalse(try PdfDocument.open(XCTUnwrap(made.bytes)).isEncrypted)
    }

    func test_aFileOpenedWithOnlyTheUserPasswordIsRefusedNotThrown() async throws {
        let tab = try tabOf(protectedFile(), password: "open")

        let made = try ConvertJob(tab, SecurityHost()).run(.a2b, FakeFonts())

        XCTAssertNil(made.bytes)
        XCTAssertEqual(made.refusal, PdfAText.noRights)
    }

    #if canImport(Security)
    func test_aFileOpenedWithACertificateIsConvertedNotRefusedAsUnreadable() async throws {
        let alice = try PdfDigitalId.create("Alice", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 20, keyBits: 2048, encipher: true)
        let held = try XCTUnwrap(PdfCertificate(alice))
        let security = try PdfSecurity.createPublicKey([PdfRecipient(held)], .aes256)
        let bytes = try PdfDocument.open(Pdfs.text()).saveRewrite(PdfSaveOptions(security: security))
        let choice = CertificateChoice(alice)
        let host = SecurityHost()
        host.keys[choice.id] = alice
        let tab = DocumentTab(session: try PdfEditSession.open(bytes, certificate: held), renderer: FakeRenderer(), url: nil,
                              title: "Quarterly report.pdf", certificate: choice)

        let made = try ConvertJob(tab, host).run(.a2b, FakeFonts())

        XCTAssertFalse(try PdfDocument.open(XCTUnwrap(made.bytes)).isEncrypted)
    }
    #endif

    func test_whatConvertingCostsIsSaidBeforeItIsDone() async {
        XCTAssertEqual(StandardsText.losses(signed: false, encrypted: false), "")
        XCTAssertTrue(StandardsText.losses(signed: true, encrypted: false).contains("signatures"))
        XCTAssertTrue(StandardsText.losses(signed: false, encrypted: true).contains("password"))
        XCTAssertTrue(StandardsText.losses(signed: true, encrypted: true).contains("signatures"))
        XCTAssertTrue(StandardsText.losses(signed: true, encrypted: true).contains("password"))
    }

    func test_theResultListsEveryChangeAndOnlyClaimsPassingChecksWhenItIsClean() async {
        let clean = PdfAConversion([1], nil, [], [PdfAText.encryptionRemoved, PdfAText.signaturesBroken, PdfAText.layersRemoved])
        let broken = PdfAConversion([1], nil, [PdfAIssue("6.1.3", PdfAText.trailer, "The trailer has no /ID.")], [PdfAText.attachmentsRemoved(2)])

        let passed = StandardsText.convertedText(clean, .a2b)
        let still = StandardsText.convertedText(broken, .a2b)

        XCTAssertTrue(passed.contains("passes Lazy PDF's checks for PDF/A-2b"))
        XCTAssertTrue(passed.contains(PdfAText.encryptionRemoved))
        XCTAssertTrue(passed.contains(PdfAText.signaturesBroken))
        XCTAssertTrue(passed.contains(PdfAText.layersRemoved))
        XCTAssertTrue(still.contains("still breaks 1 rules"))
        XCTAssertTrue(still.contains(PdfAText.attachmentsRemoved(2)))
        XCTAssertNotEqual(StandardsText.convertedTitle(clean), StandardsText.convertedTitle(broken))
        XCTAssertFalse(StandardsText.convertedTitle(broken).contains("PDF/A-2b"))
    }

    func test_theNewTabNameKeepsTheFileNameWhenItIsCutAtASlash() async {
        let clean = StandardsText.convertedName("Quarterly report.pdf", .a2b, clean: true)
        let broken = StandardsText.convertedName(clean, .a3b, clean: false)

        XCTAssertEqual(clean, "Quarterly report (PDF-A-2b).pdf")
        XCTAssertEqual(broken, "Quarterly report (PDF-A-2b) (converted).pdf")
        XCTAssertEqual((clean as NSString).deletingPathExtension, "Quarterly report (PDF-A-2b)")
    }

    func test_aCopyOfATabIsReadOnTheWorkerFromTheBytesOfTheMomentItWasAskedFor() async throws {
        let tab = try tabOf(Pdfs.text())
        let open = OpenCopy.of(tab, SecurityHost())
        try Pdfs.retitle(tab.session, "Newer")
        try tab.commit("Title")

        let copy = try await Task.detached { try open() }.value

        XCTAssertNotEqual(DocumentMetadata.read(copy).title, "Newer")
        XCTAssertFalse(copy === tab.document)
    }
}
