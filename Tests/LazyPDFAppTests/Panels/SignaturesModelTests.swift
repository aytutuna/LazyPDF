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

    func test_whileTheCheckRunsThePanelSaysSo() async throws {
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

    func test_aFileOpenedWithACertificateAsksTheWindowForTheKey() async throws {
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

    private func signedField() -> [UInt8] {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] >>",
            "<< /Type /Page /Parent 2 0 R /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (s) /V 5 0 R /Rect [0 0 100 20] /P 3 0 R >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite >>",
        ]
        var file = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(file.utf8)
    }

    func test_clearingASignatureEmptiesItsFieldInOneUndoStep() async throws {
        let rig = try await attached(signedField())

        XCTAssertTrue(rig.model.clear("s"))

        XCTAssertEqual(PdfForm.read(rig.tab.document).find("s")?.isSigned, false)
        XCTAssertTrue(try rig.tab.undo())
        XCTAssertEqual(PdfForm.read(rig.tab.document).find("s")?.isSigned, true)
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_clearingAFieldThatIsNotSignedIsToldAndChangesNothing() async throws {
        let rig = try await attached(Pdfs.text())

        XCTAssertFalse(rig.model.clear("Nothing"))

        XCTAssertEqual(rig.host.problems.count, 1)
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_clearingASignatureWarnsWhenLaterSignaturesFollow() {
        func row(_ index: Int, _ revision: Int) -> SignatureRow {
            var report = SignatureReport()
            report.index = index
            report.revision = revision
            return SignatureRow(report, page: 0, area: nil)
        }
        let rows = [row(0, 1), row(1, 2)]
        let warning = "Signatures made after it will show the file as changed."

        XCTAssertTrue(SignaturesModel.clearText(rows, rows[0]).hasSuffix(warning))
        XCTAssertFalse(SignaturesModel.clearText(rows, rows[1]).contains(warning))
    }

    func test_longListsOfServersAreShortened() {
        XCTAssertEqual(ServerPreview.describe(["a", "b"]), "a, b")
        XCTAssertEqual(ServerPreview.describe((1...8).map { "s\($0)" }), "s1, s2, s3, s4, s5, s6, and 2 more")
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

    func test_aSignedFieldIsClearedOnlyAfterTheNoticeIsAnswered() async throws {
        let (file, _) = try signedFile(comment: false)
        let rig = try await attached(file)
        XCTAssertTrue(rig.model.canClearSignature)

        rig.model.clearSignature()

        let notice = try XCTUnwrap(rig.host.notices.first)
        let name = try XCTUnwrap(rig.model.selectedRow?.report.fieldName)
        XCTAssertEqual(notice.title, "Clear the signature of \(name)?")
        XCTAssertEqual(notice.action?.text, "Clear signature")
        XCTAssertTrue(PdfForm.read(rig.tab.document).fields.contains { $0.isSigned })
        notice.action?.run()
        XCTAssertFalse(PdfForm.read(rig.tab.document).fields.contains { $0.isSigned })
        await settle { !rig.model.canClearSignature }
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

    func test_theSignerIsTrustedFromTheButton() async throws {
        let (file, _) = try signedFile(comment: false)
        let rig = try await attached(file)
        XCTAssertTrue(rig.model.canTrustSigner)

        rig.model.trustSigner()

        XCTAssertEqual(rig.model.trusted.map { $0.name }, ["Ada Lovelace"])
        XCTAssertFalse(rig.model.canTrustSigner)
        await settle { rig.model.rows.first?.level == .good }
    }

    func test_theServersAreAskedOnlyWhenAskedAndOnlyWhereATransportWasGiven() async throws {
        let (file, _) = try signedFile(comment: false)
        let without = try await attached(file)
        XCTAssertFalse(without.model.canAskServers)

        let dir = TempDir(self)
        let tab = try PanelPdfs.tab(file)
        let transport = SilentTransport()
        let model = SignaturesModel(trust: SignatureTrust(directory: dir.url), transport: { transport })
        model.attach(tab, PanelViewer(tab), RecordingHost())
        await model.check().value
        XCTAssertNotEqual(model.note, "Checked with the certificate servers just now. The file is not changed.")
        XCTAssertTrue(model.canAskServers)
        XCTAssertEqual(transport.requests, 0)

        // A self-signed signer names no server, so nothing is asked and the note does not claim it was.
        model.askServers()
        await settle { model.note == "The certificates name no servers to ask." }
        XCTAssertEqual(transport.requests, 0)
    }

    func test_closingThePanelEndsTheRequestsInFlight() async throws {
        let (file, _) = try signedFile(comment: false)
        let tab = try PanelPdfs.tab(file)
        let transport = SilentTransport()
        let model = SignaturesModel(trust: SignatureTrust(directory: TempDir(self).url), transport: { transport })
        model.attach(tab, PanelViewer(tab), RecordingHost())

        let running = model.check(online: true)
        XCTAssertFalse(transport.cancelled)
        model.detach()
        await running.value

        XCTAssertTrue(transport.cancelled)
    }

    func test_aNewCheckEndsTheRequestsOfTheLastOne() async throws {
        let (file, _) = try signedFile(comment: false)
        let tab = try PanelPdfs.tab(file)
        let transport = SilentTransport()
        let model = SignaturesModel(trust: SignatureTrust(directory: TempDir(self).url), transport: { transport })
        model.attach(tab, PanelViewer(tab), RecordingHost())

        model.check(online: true)
        await model.check().value

        XCTAssertTrue(transport.cancelled)
    }

    func test_theSignersCertificateIsHandedToTheView() async throws {
        let (file, certificate) = try signedFile(comment: false)
        let rig = try await attached(file)
        var shown: [X509Certificate] = []
        rig.model.showCertificate = { shown.append($0); return true }

        rig.model.viewCertificate()

        XCTAssertEqual(shown.map(\.rawData), [certificate.rawData])
        XCTAssertNil(rig.model.versionProblem)
    }

    func test_aCertificateIsDescribedByItsOwnFields() async throws {
        let (_, certificate) = try signedFile(comment: false)

        let facts = SignaturesModel.facts(of: certificate)

        XCTAssertEqual(facts.count, 4)
        XCTAssertEqual(facts[0], "Issued to " + certificate.subject)
        XCTAssertEqual(facts[3], "Thumbprint " + certificate.thumbprint)
    }

    func test_aCertificateThatCannotBeShownIsToldInTheNote() async throws {
        let (file, _) = try signedFile(comment: false)
        let rig = try await attached(file)
        rig.model.showCertificate = { _ in false }

        rig.model.viewCertificate()

        XCTAssertEqual(rig.model.versionProblem, "The certificate could not be shown.")
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

private final class SilentTransport: SigningTransport {
    var lastFailure: String? { "No connection." }
    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? { nil }
    func get(_ url: String) -> [UInt8]? { requests += 1; return nil }
    func cancel() { cancelled = true }
    var requests = 0
    var cancelled = false
}
