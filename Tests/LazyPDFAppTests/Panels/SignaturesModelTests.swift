import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Signatures panel: the check, the details, the signed version and the trust settings. Windows tests the row
// (SignatureRowTests) and the trust settings file (SigningSettingsTests, with the Certificates tool); the panel's flow itself
// has no test there.

@MainActor
final class SignaturesModelTests: XCTestCase {
    private struct Rig {
        let model: SignaturesModel
        let viewer: PanelViewer
        let tab: DocumentTab
        let host: RecordingHost
        let dir: TempDir
    }

    private func attached(_ bytes: [UInt8], title: String = "a.pdf") async throws -> Rig {
        let dir = TempDir(self)
        let tab = try PanelPdfs.tab(bytes, title: title)
        let viewer = PanelViewer(tab)
        let host = RecordingHost()
        let model = SignaturesModel(trust: SignatureTrust(directory: dir.url))
        model.attach(tab, viewer, host)
        await model.check().value
        return Rig(model: model, viewer: viewer, tab: tab, host: host, dir: dir)
    }

    func test_aFileWithoutSignaturesSaysSo() async throws {
        let rig = try await attached(Pdfs.text())

        XCTAssertTrue(rig.model.rows.isEmpty)
        XCTAssertEqual(rig.model.note, "This file has no signatures.")
        XCTAssertNil(rig.model.selectedRow)
    }

    func test_whileTheCheckRunsThePanelSaysSo() throws {
        let tab = try PanelPdfs.tab(Pdfs.text())
        let model = SignaturesModel(trust: SignatureTrust(directory: TempDir(self).url))

        model.attach(tab, PanelViewer(tab), RecordingHost())

        XCTAssertEqual(model.note, "Checking the signatures")
    }

    func test_choosingASignatureShowsItsFieldOnThePage() async throws {
        let rig = try await attached(Pdfs.text(2))
        let row = SignatureRow(SignatureReport(), page: 1, area: ViewRect(10, 20, 30, 40))

        rig.model.go(row)
        rig.model.go(SignatureRow(SignatureReport(), page: -1, area: nil))

        XCTAssertEqual(rig.viewer.sent, [1])
        XCTAssertEqual(rig.viewer.revealed.map { $0.page }, [1])
        XCTAssertEqual(rig.viewer.revealed[0].area, ViewRect(10, 20, 30, 40))
    }

    func test_aCertificateThatIsNotOneIsRefusedAndNothingIsKept() async throws {
        let rig = try await attached(Pdfs.text())

        rig.model.addTrusted(Array("not a certificate".utf8))

        XCTAssertEqual(rig.model.trustNote, "That file is not a certificate. Choose a .cer or .crt file.")
        XCTAssertTrue(rig.model.trusted.isEmpty)
    }

    func test_theSystemRootsSettingIsKeptForTheNextRun() async throws {
        let rig = try await attached(Pdfs.text())
        XCTAssertTrue(rig.model.trustsSystem)

        rig.model.setTrustsSystem(false)

        XCTAssertFalse(rig.model.trustsSystem)
        XCTAssertFalse(SignatureTrust(directory: rig.dir.url).trustsSystem)
    }

    func test_theSignedVersionIsOfferedOnlyWhereTheFileWentOn() async throws {
        let rig = try await attached(Pdfs.text())

        XCTAssertFalse(rig.model.canSaveSigned)
        XCTAssertFalse(rig.model.canViewSigned)
        XCTAssertNil(rig.model.signedVersionFile())
    }

    func test_theOutcomeOfSavingTheSignedVersionIsToldToTheWindow() async throws {
        let rig = try await attached(Pdfs.text())
        let url = URL(fileURLWithPath: "/tmp/a (signed).pdf")

        rig.model.signedVersionSaved(.success(url))

        XCTAssertEqual(rig.host.statuses, ["Signed version saved."])
        let notice = try XCTUnwrap(rig.host.notices.first)
        XCTAssertEqual(notice.title, "Signed version saved")
        XCTAssertEqual(notice.text, "a (signed).pdf")
        XCTAssertEqual(notice.action?.text, "Open it")
        notice.action?.run()
        await settle { rig.host.opened == [url] }

        rig.model.signedVersionSaved(.failure(CocoaError(.fileWriteUnknown)))
        XCTAssertEqual(rig.model.versionProblem, "The file could not be saved. Check the folder and try again.")
    }

    func test_aSignedVersionIsNotSavedOverTheOpenFile() async throws {
        let dir = TempDir(self)
        let url = dir.url.appendingPathComponent("a.pdf")
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: url, title: "a.pdf")
        let host = RecordingHost()
        let model = SignaturesModel(trust: SignatureTrust(directory: dir.url))
        model.attach(tab, PanelViewer(tab), host)

        model.signedVersionSaved(.success(url))

        XCTAssertEqual(model.versionProblem, "That is the open file. Choose another name.")
        XCTAssertTrue(host.notices.isEmpty)
    }

    func test_theSavedFileIsOpenedWithTheGrantTheViewAsksFor() async throws {
        let rig = try await attached(Pdfs.text())
        let url = URL(fileURLWithPath: "/tmp/b.pdf")
        let grant = Grant()

        rig.model.signedVersionSaved(.success(url), access: { _ in grant })
        rig.host.notices[0].action?.run()
        await settle { rig.host.opened == [url] }

        XCTAssertTrue(rig.host.openedAccess[0] === grant)
    }

    func test_aFileOpenedWithACertificateAsksTheWindowForTheKey() throws {
        let dir = TempDir(self)
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: nil, title: "a.pdf",
                              certificate: FakeKeys.alice)
        let host = RecordingHost()
        let model = SignaturesModel(trust: SignatureTrust(directory: dir.url))
        model.attach(tab, PanelViewer(tab), host)

        XCTAssertEqual(host.certificatesAsked, [FakeKeys.alice])
        XCTAssertEqual(model.note, "The signatures could not be checked.")
    }

    func test_aFieldNoPageListsIsNotAskedForItsGeometry() async throws {
        let rig = try await attached(Pdfs.text())
        var report = SignatureReport()
        report.fieldName = "Sig1"
        let fields = ["Sig1": (page: -1, rect: PdfRect(0, 0, 10, 10))]

        let row = rig.model.row(report, fields)

        XCTAssertEqual(row.page, -1)
        XCTAssertNil(row.area)
        XCTAssertTrue(rig.viewer.geometryAsked.isEmpty)
    }

    #if canImport(Security)
    private static let now = DateTimeOffset(2026, 3, 10, 9, 0, 0)

    private func signedFile(comment: Bool) throws -> (file: [UInt8], certificate: X509Certificate) {
        let ada = try PdfDigitalId.create("Ada Lovelace", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 1, keyBits: 2048)
        let session = try PdfEditSession.open(Pdfs.text())
        var request = PdfSignRequest(ada, Self.now)
        request.fonts = FakeFonts()
        try PdfSigner.sign(session, request)
        if comment {
            _ = try PdfAnnotationWriter(session.document).addNote(session.document.pages[0], PdfRect(10, 10, 30, 30), AnnotationInfo(contents: "hi"))
            _ = try session.commit("Comment")
        }
        return (session.current, ada)
    }

    func test_eachSignatureIsListedAndTheFirstIsPicked() async throws {
        let (file, _) = try signedFile(comment: false)
        let rig = try await attached(file)

        XCTAssertEqual(rig.model.rows.map { $0.title }, ["Ada Lovelace"])
        XCTAssertNil(rig.model.note)
        XCTAssertEqual(rig.model.selectedRow?.id, 0)
        XCTAssertEqual(rig.model.versionText, "This is the signed version.")
        XCTAssertFalse(rig.model.canSaveSigned)
    }

    func test_trustingTheSignersCertificateMakesTheSignatureGood() async throws {
        let (file, certificate) = try signedFile(comment: false)
        let rig = try await attached(file)
        XCTAssertEqual(rig.model.rows[0].level, .caution)

        rig.model.addTrusted(certificate.rawData)

        XCTAssertNil(rig.model.trustNote)
        XCTAssertEqual(rig.model.trusted.map { $0.name }, ["Ada Lovelace"])
        await settle { rig.model.rows.first?.level == .good }

        rig.model.removeTrusted(rig.model.trusted[0])
        XCTAssertTrue(rig.model.trusted.isEmpty)
        await settle { rig.model.rows.first?.level == .caution }
    }

    func test_aCertificateInAPemFileIsTaken() async throws {
        let (file, certificate) = try signedFile(comment: false)
        let rig = try await attached(file)
        let body = Data(certificate.rawData).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"

        rig.model.addTrusted(Array(pem.utf8))

        XCTAssertEqual(rig.model.trusted.count, 1)
        rig.model.addTrusted(certificate.rawData)
        XCTAssertEqual(rig.model.trusted.count, 1)
    }

    func test_theSignedVersionOpensAsACopyAndIsOfferedForSaving() async throws {
        let (file, _) = try signedFile(comment: true)
        let rig = try await attached(file)
        XCTAssertTrue(rig.model.canViewSigned)
        XCTAssertTrue(rig.model.canSaveSigned)
        XCTAssertEqual(rig.model.rows[0].level, .bad)

        await rig.model.viewSigned()

        let opened = try XCTUnwrap(rig.host.openedNew.first)
        XCTAssertEqual(opened.title, "a (signed by Ada Lovelace)")
        XCTAssertLessThan(opened.pdf.count, file.count)
        let offered = try XCTUnwrap(rig.model.signedVersionFile())
        XCTAssertEqual(offered.name, "a (signed).pdf")
        XCTAssertEqual(offered.bytes, opened.pdf)
    }
    #endif
}
