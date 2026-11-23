#if canImport(Security)
import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// The Certificates panel as the window drives it. Windows has no test of the panel itself; its pieces are tested with
// CertificateSigningTests, SigningFailureTests and SigningSettingsTests. These cover the choices, the box, the identities, the
// run and what it says.

@MainActor
final class CertificatesModelTests: XCTestCase {
    private var transport: SigningTransport = DownServer()

    private let picture = PdfRgbaImage(150, 50, [UInt8](repeating: 0, count: 150 * 50 * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : 0 })

    private struct Setup {
        let model: CertificatesModel
        let rig: SecurityRig
        let ada: X509Certificate
        let choice: CertificateChoice
        let store: SavedSignatures
        let codec: SignaturePictureCodec
    }

    private func made(_ folder: TempDir, fonts: FontSource? = nil, store: SavedSignatures? = nil, codec: ImageCodec? = nil,
                      transport: @escaping () -> SigningTransport = { DownServer() },
                      importIdentity: @escaping ([UInt8], String) throws -> X509Certificate) -> CertificatesModel {
        let codec = codec ?? SignaturePictureCodec(picture)
        return CertificatesModel(trust: SignatureTrust(directory: folder.url), fonts: fonts,
                                 store: store ?? SavedSignatures(directory: folder.sub("Signatures"), codec: codec),
                                 system: StubSignatureSystem(), codec: codec, transport: transport, importIdentity: importIdentity)
    }

    private func attached(_ bytes: [UInt8]? = nil, password: String? = nil, field: String? = nil, saved: Int = 0) throws -> Setup {
        let rig = try SecurityRig(bytes, password: password)
        let ada = try CertificateKit.ada()
        let choice = CertificateChoice(ada)
        rig.host.identities = [choice]
        rig.host.keys[choice.id] = ada
        rig.host.signingField = field
        let folder = TempDir(self)
        let transport = self.transport
        let codec = SignaturePictureCodec(picture)
        let store = SavedSignatures(directory: folder.sub("Signatures"), codec: codec)
        for _ in 0..<saved { try store.add(.signature, picture) }
        let model = made(folder, fonts: FakeFonts(), store: store, codec: codec, transport: { transport }, importIdentity: { bytes, password in
            if password != "right" { throw SignatureCryptoException(message: "Wrong password.") }
            return ada
        })
        rig.attach(model)
        return Setup(model: model, rig: rig, ada: ada, choice: choice, store: store, codec: codec)
    }

    private func drawBox(_ s: Setup) throws {
        try drawBox(s.model, s.rig)
    }

    private func drawBox(_ model: CertificatesModel, _ rig: SecurityRig) throws {
        model.setPlace(1)
        model.drawBox()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)
        func pointer(_ x: Double, _ y: Double, _ pressed: Bool) -> PagePointer {
            PagePointer(page: 1, point: ViewPoint(x, y), view: ViewPoint(x, y), pressed: pressed, clicks: pressed ? 0 : 1)
        }
        tool.press(pointer(20, 30, true))
        tool.move(pointer(220, 90, true))
        tool.release(pointer(220, 90, false))
    }

    private func appearanceResources(_ s: Setup) throws -> PdfDictionary {
        try appearanceResources(s.rig)
    }

    private func appearanceResources(_ rig: SecurityRig) throws -> PdfDictionary {
        let document = rig.tab.document
        let widget = try XCTUnwrap(PdfAnnotations.readAll(document).first { $0.type == .widget })
        let form = try XCTUnwrap(document.stream(document.dict(widget.dictionary, "AP"), "N"))
        return try XCTUnwrap(document.dict(form.dictionary, "Resources"))
    }

    private func keepOne(_ s: Setup, keep: Bool = true) {
        s.model.makeNew()
        s.model.maker.setName("Ada")
        s.model.maker.keep = keep
        s.model.useMade()
    }

    private func emptyFieldFile() throws -> [UInt8] {
        let session = try PdfEditSession.open(Pdfs.text())
        _ = try PdfForm.read(session.document).addField(FieldSpec(.signature, "Approval", 0, PdfRect(72, 100, 200, 150)))
        try session.commit("Field")
        return session.current
    }

    func test_aPictureLookNeedsAPictureToBePicked() async throws {
        let s = try attached()
        s.model.lookIndex = 1
        XCTAssertFalse(s.model.showsLook)
        try drawBox(s)
        XCTAssertTrue(s.model.showsLook)
        XCTAssertTrue(s.model.needsPicture)
        XCTAssertFalse(s.model.action!.canRun())

        keepOne(s)

        XCTAssertTrue(s.model.action!.canRun())
        s.model.lookIndex = 0
        XCTAssertFalse(s.model.needsPicture)
    }

    func test_aPictureMadeForOneSigningOnlyIsTheFirstRowAndIsNotKept() async throws {
        let s = try attached(saved: 1)
        XCTAssertEqual(s.model.rows.count, 1)

        keepOne(s, keep: false)

        XCTAssertEqual(s.model.rows.first?.id, PictureRow.oneOffID)
        XCTAssertEqual(s.model.rows.first?.name, "This signature only")
        XCTAssertEqual(s.model.selected, PictureRow.oneOffID)
        XCTAssertEqual(s.model.rows.count, 2)
        XCTAssertEqual(s.store.list(.signature).count, 1)
        XCTAssertFalse(s.model.showMaker)
    }

    func test_aPictureThatIsKeptIsSelectedAndListed() async throws {
        let s = try attached(saved: 1)

        keepOne(s)

        XCTAssertEqual(s.store.list(.signature).count, 2)
        XCTAssertEqual(s.model.rows.count, 2)
        XCTAssertNil(s.model.oneOff)
        XCTAssertEqual(s.model.selected, s.store.list(.signature)[0].url.lastPathComponent)
    }

    func test_aPictureThatCannotBeKeptIsStillUsedForTheSigning() async throws {
        let folder = TempDir(self)
        let blocker = folder.sub("blocked")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data([1]).write(to: blocker)
        let rig = try SecurityRig()
        let ada = try CertificateKit.ada()
        let choice = CertificateChoice(ada)
        rig.host.identities = [choice]
        rig.host.keys[choice.id] = ada
        let codec = SignaturePictureCodec(picture)
        let store = SavedSignatures(directory: blocker.appendingPathComponent("inside"), codec: codec)
        let model = made(folder, fonts: FakeFonts(), store: store, codec: codec, importIdentity: { _, _ in ada })
        rig.attach(model)
        model.lookIndex = 1
        model.makeNew()
        model.maker.setName("Ada")

        model.useMade()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Signature not kept"])
        XCTAssertEqual(rig.host.problems.first?.text, "It could not be saved. It will be used for this signing only.")
        XCTAssertEqual(model.selected, PictureRow.oneOffID)
        XCTAssertNotNil(model.oneOff)
        try drawBox(model, rig)
        XCTAssertTrue(model.canSign)

        await model.action!.run()

        XCTAssertTrue(rig.tab.document.isSigned)
        XCTAssertTrue(try appearanceResources(rig).containsKey("XObject"))
    }

    func test_aPictureOnlyLookWritesNoSignerText() async throws {
        let s = try attached(saved: 1)
        s.model.lookIndex = 2
        try drawBox(s)

        await s.model.action!.run()

        XCTAssertTrue(s.rig.tab.document.isSigned)
        let found = try appearanceResources(s)
        XCTAssertTrue(found.containsKey("XObject"))
        XCTAssertFalse(found.containsKey("Font"))
    }

    func test_aPictureAndTextLookKeepsTheText() async throws {
        let s = try attached(saved: 1)
        s.model.lookIndex = 1
        try drawBox(s)

        await s.model.action!.run()

        let found = try appearanceResources(s)
        XCTAssertTrue(found.containsKey("XObject"))
        XCTAssertTrue(found.containsKey("Font"))
    }

    func test_anInvisibleSignatureIgnoresTheLook() async throws {
        let s = try attached()
        s.model.lookIndex = 2
        s.model.setPlace(1)
        XCTAssertTrue(s.model.needsPicture)

        s.model.setPlace(0)

        XCTAssertFalse(s.model.showsLook)
        XCTAssertFalse(s.model.needsPicture)
        XCTAssertTrue(s.model.action!.canRun())
        await s.model.action!.run()
        XCTAssertTrue(s.rig.tab.document.isSigned)
        XCTAssertTrue(s.rig.host.problems.isEmpty)
    }

    func test_aSavedPictureThatCannotBeReadSignsNothing() async throws {
        let s = try attached(saved: 1)
        s.model.lookIndex = 1
        try drawBox(s)
        s.codec.frame = nil

        await s.model.action!.run()

        XCTAssertEqual(s.rig.host.problems.map(\.title), ["Signature not read"])
        XCTAssertFalse(s.rig.tab.document.isSigned)
        XCTAssertFalse(s.rig.tab.session.canUndo)
    }

    func test_afterASigningThePictureForOneSigningIsGoneAndTheFirstRowIsSelected() async throws {
        let s = try attached(saved: 1)
        keepOne(s, keep: false)
        s.model.lookIndex = 1
        try drawBox(s)
        XCTAssertEqual(s.model.selected, PictureRow.oneOffID)

        await s.model.action!.run()

        XCTAssertNil(s.model.oneOff)
        XCTAssertEqual(s.model.rows.count, 1)
        XCTAssertEqual(s.model.selected, s.store.list(.signature)[0].url.lastPathComponent)
    }

    func test_withNothingSavedNothingIsSelectedAfterASigning() async throws {
        let s = try attached()
        keepOne(s, keep: false)
        s.model.lookIndex = 1
        try drawBox(s)

        await s.model.action!.run()

        XCTAssertTrue(s.rig.tab.document.isSigned)
        XCTAssertTrue(s.model.rows.isEmpty)
        XCTAssertNil(s.model.selected)
        XCTAssertFalse(s.model.canSign)
    }

    func test_attachingSelectsTheNewestSavedPictureAndLeavingForgetsTheOneForOneSigning() async throws {
        let s = try attached(saved: 2)

        XCTAssertEqual(s.model.selected, s.store.list(.signature)[0].url.lastPathComponent)

        keepOne(s, keep: false)
        s.model.detach()

        XCTAssertNil(s.model.oneOff)
        XCTAssertFalse(s.model.showMaker)
    }

    func test_theKeychainIdentitiesAreListedAndTheFirstIsChosen() async throws {
        let s = try attached()

        XCTAssertEqual(s.model.identities, [s.choice])
        XCTAssertEqual(s.model.selectedIdentity, s.choice.id)
        XCTAssertEqual(s.model.certificateNote, "")
        XCTAssertTrue(s.model.action!.canRun())
        XCTAssertEqual(s.model.places.map(\.text), ["Not visible", "A box I draw on the page"])
    }

    func test_withoutAnIdentityTheNoteSaysSoAndTheButtonWaits() async throws {
        let rig = try SecurityRig()
        let model = made(TempDir(self), importIdentity: { _, _ in throw SignatureCryptoException(message: "") })
        rig.attach(model)

        XCTAssertEqual(model.certificateNote, "The keychain has no certificate with a private key for you. Use a .p12 file.")
        XCTAssertFalse(model.action!.canRun())
    }

    func test_aSignatureIsMadeInTheOpenDocumentAndCanBeUndone() async throws {
        let s = try attached()

        await s.model.action!.run()

        XCTAssertTrue(s.rig.tab.document.isSigned)
        XCTAssertTrue(s.rig.tab.session.canUndo)
        XCTAssertTrue(s.rig.tab.isDirty)
        XCTAssertEqual(s.rig.host.statuses.last, "File signed.")
        XCTAssertEqual(s.rig.host.busyTexts, ["Signing the file"])
        XCTAssertFalse(s.model.working)
        XCTAssertTrue(s.rig.host.openedNew.isEmpty)
        XCTAssertTrue(s.model.isSigned)
    }

    func test_aBoxDrawnOnThePageIsWhereTheSignatureGoes() async throws {
        let s = try attached()

        s.model.setPlace(1)
        XCTAssertFalse(s.model.action!.canRun())
        XCTAssertEqual(s.model.boxText, "No box yet.")
        s.model.drawBox()
        XCTAssertEqual(s.model.boxText, "Drag on the page where it goes.")
        let tool = try XCTUnwrap(s.rig.viewer.pointerTool)
        func pointer(_ x: Double, _ y: Double, _ pressed: Bool) -> PagePointer {
            PagePointer(page: 1, point: ViewPoint(x, y), view: ViewPoint(x, y), pressed: pressed, clicks: pressed ? 0 : 1)
        }
        tool.press(pointer(20, 30, true))
        tool.move(pointer(120, 90, true))
        XCTAssertNotNil(s.rig.viewer.overlay(1).item("certificates.preview"))
        tool.release(pointer(120, 90, false))

        XCTAssertEqual(s.model.boxText, "Box drawn on page 2.")
        XCTAssertNil(s.rig.viewer.pointerTool)
        XCTAssertNil(s.rig.viewer.overlay(1).item("certificates.preview"))
        XCTAssertNotNil(s.rig.viewer.overlay(1).item("certificates.box"))
        XCTAssertTrue(s.model.action!.canRun())

        await s.model.action!.run()
        await waitUntil { s.rig.viewer.overlay(1).item("certificates.box") == nil }

        let widget = try XCTUnwrap(PdfAnnotations.readAll(s.rig.tab.document).first { $0.type == .widget })
        XCTAssertEqual(widget.pageIndex, 1)
        XCTAssertEqual(widget.rect.left, 20, accuracy: 0.5)
        XCTAssertEqual(widget.rect.right, 120, accuracy: 0.5)
    }

    func test_aBoxThatIsTooSmallIsNotTaken() async throws {
        let s = try attached()
        s.model.setPlace(1)
        s.model.drawBox()
        let tool = try XCTUnwrap(s.rig.viewer.pointerTool)

        tool.press(PagePointer(page: 0, point: ViewPoint(20, 30), view: ViewPoint(20, 30), pressed: true, clicks: 0))
        tool.release(PagePointer(page: 0, point: ViewPoint(25, 35), view: ViewPoint(25, 35), pressed: false, clicks: 1))

        XCTAssertFalse(s.model.action!.canRun())
    }

    func test_aKeyboardClickGetsABoxOfTheUsualSizeInsideThePage() async throws {
        let s = try attached()
        s.model.setPlace(1)
        s.model.drawBox()
        let tool = try XCTUnwrap(s.rig.viewer.pointerTool)
        let at = ViewPoint(600, 780)

        tool.press(PagePointer(page: 0, point: at, view: at, pressed: true, clicks: 0))
        tool.release(PagePointer(page: 0, point: at, view: at, pressed: false, clicks: 1, fromKeys: true))

        XCTAssertEqual(s.model.boxText, "Box drawn on page 1.")
        XCTAssertTrue(s.model.action!.canRun())
    }

    func test_anEmptyFieldAskedForByTheSignaturesPanelIsChosenAndSigned() async throws {
        let s = try attached(try emptyFieldFile(), field: "Approval")

        XCTAssertEqual(s.model.places.map(\.text), ["Not visible", "A box I draw on the page", "Field Approval"])
        XCTAssertEqual(s.model.place?.place, .field("Approval"))

        await s.model.action!.run()

        XCTAssertTrue(CertificateSigning.emptyFields(s.rig.tab.document).isEmpty)
        XCTAssertEqual(s.rig.host.statuses.last, "File signed.")
        XCTAssertNil(s.rig.host.takeSigningField())
    }

    func test_aFileThatDoesNotAllowItIsRefusedBeforeAnythingIsAsked() async throws {
        let s = try attached(try Pdfs.restricted(.print), password: "")

        await s.model.action!.run()

        XCTAssertEqual(s.rig.host.problems.map(\.title), ["This file cannot be signed"])
        XCTAssertFalse(s.rig.tab.document.isSigned)
    }

    func test_theTimeStampNeedsAWebAddressAndAFailedOneLeavesTheFileAsItWas() async throws {
        let s = try attached()
        s.model.timestamp = true
        s.model.timestampUrl = "timestamp.example"
        XCTAssertEqual(s.model.urlNote, "Use a web address that starts with http:// or https://.")
        XCTAssertFalse(s.model.action!.canRun())

        s.model.timestampUrl = "http://timestamp.example"
        XCTAssertEqual(s.model.urlNote, "")

        s.model.timestampUrl = ""
        XCTAssertEqual(s.model.urlNote, "")

        s.model.timestampUrl = "https://tsa.example/stamp"
        XCTAssertEqual(s.model.urlNote, "")
        XCTAssertTrue(s.model.action!.canRun())
        await s.model.action!.run()

        let problem = try XCTUnwrap(s.rig.host.problems.first)
        XCTAssertEqual(problem.title, "Not signed")
        XCTAssertEqual(problem.text, SignatureText.noTimestamp + " The server did not answer.")
        XCTAssertFalse(s.rig.tab.document.isSigned)
        XCTAssertFalse(s.rig.tab.session.canUndo)
        XCTAssertFalse(s.model.working)
    }

    func test_theLastTimeStampServerIsKeptWithTheTrustSettings() async throws {
        let rig = try SecurityRig()
        let folder = TempDir(self)
        SignatureTrust(directory: folder.url).setTimestampUrl("https://tsa.example/stamp")
        let model = made(folder, importIdentity: { _, _ in throw SignatureCryptoException(message: "") })

        rig.attach(model)

        XCTAssertEqual(model.timestampUrl, "https://tsa.example/stamp")
    }

    func test_theTimeStampServerStartsWithTheSuggestedAddress() async throws {
        let rig = try SecurityRig()
        let model = made(TempDir(self), importIdentity: { _, _ in throw SignatureCryptoException(message: "") })

        rig.attach(model)

        XCTAssertEqual(model.timestampUrl, "http://timestamp.digicert.com")
        XCTAssertTrue(CertificateSigning.isWebAddress(model.timestampUrl))
    }

    func test_aP12FileIsReadWithItsPasswordAndAWrongOneIsSaidSo() async throws {
        let s = try attached()
        let folder = TempDir(self)
        let file = folder.file("me.p12", [1, 2, 3])
        s.model.useKeychain = false
        XCTAssertFalse(s.model.action!.canRun())
        s.rig.host.picked = [ToolFile(url: file)]

        await s.model.chooseFile()

        XCTAssertEqual(s.model.pfxName, "me.p12")
        XCTAssertTrue(s.model.action!.canRun())
        s.model.pfxPassword = "wrong"
        await s.model.action!.run()
        XCTAssertEqual(s.rig.host.problems.map(\.title), ["Certificate not opened"])
        XCTAssertFalse(s.rig.tab.document.isSigned)

        s.model.pfxPassword = "right"
        await s.model.action!.run()
        XCTAssertTrue(s.rig.tab.document.isSigned)
    }

    func test_leavingThePanelForgetsTheFileAndItsPassword() async throws {
        let s = try attached()
        let file = TempDir(self).file("me.p12", [1, 2, 3])
        s.model.useKeychain = false
        s.rig.host.picked = [ToolFile(url: file)]
        await s.model.chooseFile()
        s.model.pfxPassword = "right"

        s.model.detach()

        XCTAssertEqual(s.model.pfxPassword, "")
        XCTAssertEqual(s.model.pfxName, "")
        XCTAssertFalse(s.model.action!.canRun())
    }

    func test_aSignedFileCannotBeCertifiedAndOffersValidationData() async throws {
        let s = try attached()
        s.model.certifyIndex = 2
        await s.model.action!.run()
        await waitUntil { s.model.certifyIndex == 0 }

        XCTAssertTrue(s.model.isSigned)
    }

    func test_validationDataThatCouldNotBeProvedSaysWhy() async throws {
        let (signer, authority) = try CertificateKit.issued()
        var request = PdfSignRequest(signer, CertificateKit.now)
        request.chain = [authority]
        request.fonts = FakeFonts()
        let session = try PdfEditSession.open(Pdfs.text())
        try PdfSigner.sign(session, request)
        let s = try attached(session.current)

        await s.model.addValidation()

        let question = try XCTUnwrap(s.rig.host.notices.last)
        XCTAssertEqual(question.title, "These servers will be asked")
        XCTAssertEqual(s.rig.host.lastNoticeAction?.text, "Ask them")
        XCTAssertFalse(s.rig.tab.isDirty)
        s.rig.host.lastNoticeAction?.run()
        await waitUntil { s.rig.host.statuses.last == "Added without proof of revocation." }

        XCTAssertEqual(s.rig.host.statuses.last, "Added without proof of revocation.")
        XCTAssertEqual(s.rig.host.notices.last?.title, "Proof of revocation is missing")
        XCTAssertTrue(s.rig.host.notices.last?.text.hasPrefix("The server did not answer.") ?? false)
        XCTAssertTrue(s.rig.tab.isDirty)
    }

    func test_aCancelledSigningLeavesTheFileAndHoldsThePanelUntilTheJobEnds() async throws {
        let s = try attached()
        s.rig.host.token.cancel()

        await s.model.action!.run()

        XCTAssertEqual(s.rig.host.statuses.last, "Canceled.")
        await waitUntil { !s.model.working }
        XCTAssertFalse(s.rig.tab.document.isSigned)
        XCTAssertFalse(s.rig.tab.session.canUndo)
    }

    func test_theBusyBarStaysUntilACancelledJobHasReallyEnded() async throws {
        let held = HeldServer()
        transport = held
        let s = try attached()
        s.model.timestamp = true
        s.model.timestampUrl = "https://tsa.example/stamp"
        var returned = false
        let running = Task { @MainActor in
            await s.model.action!.run()
            returned = true
        }
        while held.arrived.wait(timeout: .now()) != .success { await Task.yield() }

        s.rig.host.token.cancel()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(returned)
        XCTAssertTrue(s.model.working)
        held.letGo()
        await running.value
        XCTAssertFalse(s.model.working)
        XCTAssertFalse(s.rig.tab.document.isSigned)
    }

    func test_aBoxToolStopsWhenTheFileChangesUnderIt() async throws {
        let s = try attached()
        s.model.setPlace(1)
        s.model.drawBox()
        XCTAssertNotNil(s.rig.viewer.pointerTool)

        let session = s.rig.tab.session
        _ = try PdfForm.read(session.document).addField(FieldSpec(.signature, "Approval", 0, PdfRect(72, 100, 200, 150)))
        _ = try s.rig.tab.commit("Field")

        await waitUntil { s.rig.viewer.pointerTool == nil }
        XCTAssertNil(s.rig.viewer.pointerTool)
        XCTAssertTrue(s.model.drawsBox)
        XCTAssertEqual(s.model.boxText, "No box yet.")
    }

    private func drawnBox(_ s: Setup) throws {
        s.model.setPlace(1)
        s.model.drawBox()
        let tool = try XCTUnwrap(s.rig.viewer.pointerTool)
        func pointer(_ x: Double, _ y: Double, _ pressed: Bool) -> PagePointer {
            PagePointer(page: 1, point: ViewPoint(x, y), view: ViewPoint(x, y), pressed: pressed, clicks: pressed ? 0 : 1)
        }
        tool.press(pointer(20, 30, true))
        tool.move(pointer(120, 90, true))
        tool.release(pointer(120, 90, false))
    }

    func test_theKeptPlaceFollowsTheFieldWhenTheListChanges() async {
        XCTAssertEqual(CertificateSigning.keptPlace(oldIndex: 0, oldField: nil, fields: ["A", "B"]), 0)
        XCTAssertEqual(CertificateSigning.keptPlace(oldIndex: 1, oldField: nil, fields: ["A", "B"]), 1)
        XCTAssertEqual(CertificateSigning.keptPlace(oldIndex: 2, oldField: "B", fields: ["A", "B"]), 3)
        XCTAssertEqual(CertificateSigning.keptPlace(oldIndex: 2, oldField: "Gone", fields: ["A", "B"]), 0)
    }

    func test_aBoxSurvivesAChangeThatLeavesItsPageAlone() async throws {
        let s = try attached()
        try drawnBox(s)

        _ = try PdfForm.read(s.rig.tab.session.document).addField(FieldSpec(.signature, "Approval", 0, PdfRect(72, 100, 200, 150)))
        _ = try s.rig.tab.commit("Field")

        XCTAssertEqual(s.model.placeIndex, 1)
        XCTAssertEqual(s.model.boxText, "Box drawn on page 2.")
        XCTAssertNotNil(s.rig.viewer.overlay(1).item("certificates.box"))
        XCTAssertTrue(s.model.action!.canRun())
    }

    func test_aBoxIsDroppedWhenItsPageIsRotatedOrGone() async throws {
        let s = try attached()
        try drawnBox(s)
        PageOperations.rotate(s.rig.tab.document, [1], 90)
        _ = try s.rig.tab.commit("Rotate")
        await waitUntil { s.model.boxText == "No box yet." }

        XCTAssertEqual(s.model.placeIndex, 1)
        XCTAssertEqual(s.model.boxText, "No box yet.")
        XCTAssertNil(s.rig.viewer.overlay(1).item("certificates.box"))

        try drawnBox(s)
        try PageOperations.delete(s.rig.tab.document, [1])
        _ = try s.rig.tab.commit("Delete")
        await waitUntil { s.model.boxText == "No box yet." }

        XCTAssertEqual(s.model.boxText, "No box yet.")
        XCTAssertFalse(s.model.action!.canRun())
    }

    func test_aBoxIsDroppedAfterASigningRunThatChangedTheFile() async throws {
        let s = try attached()
        try drawnBox(s)

        await s.model.action!.run()
        await waitUntil { s.model.boxText == "No box yet." }

        XCTAssertNil(s.rig.viewer.overlay(1).item("certificates.box"))
        XCTAssertEqual(s.model.boxText, "No box yet.")
    }

    func test_aPressTakenAwayByASecondFingerKeepsTheBoxTool() async throws {
        let s = try attached()
        s.model.setPlace(1)
        s.model.drawBox()
        let tool = try XCTUnwrap(s.rig.viewer.pointerTool)

        tool.press(PagePointer(page: 0, point: ViewPoint(20, 30), view: ViewPoint(20, 30), pressed: true, clicks: 0))
        tool.cancel()

        XCTAssertNotNil(s.rig.viewer.pointerTool)
        XCTAssertEqual(s.model.boxText, "Drag on the page where it goes.")
        tool.cancel()
        XCTAssertNil(s.rig.viewer.pointerTool)
        XCTAssertEqual(s.model.boxText, "No box yet.")
    }

    func test_nothingIsSignedWhenTheKeychainWillNotGiveTheKey() async throws {
        let s = try attached()
        s.rig.host.keys = [:]

        await s.model.action!.run()

        XCTAssertEqual(s.rig.host.problems.map(\.title), ["Key cannot be used"])
        XCTAssertFalse(s.rig.tab.document.isSigned)
    }

    func test_theFailureWordsFollowTheKindOfError() async {
        let down = DownServer()

        XCTAssertEqual(CertificatesModel.failure(SignatureCryptoException(message: "x"), down, "Not signed").title, "Key cannot be used")
        XCTAssertEqual(CertificatesModel.failure(PdfReadException(.damaged, "x"), down, "Not signed").title, "File cannot be signed")
        XCTAssertEqual(CertificatesModel.failure(InvalidOperationException("Taken."), down, "Not signed").text, "Taken. The server did not answer.")
        XCTAssertEqual(CertificatesModel.failure(ArgumentException("Bad page."), DownServer(), "Not signed").title, "Not signed")
        down.lastFailure = nil
        XCTAssertEqual(CertificatesModel.failure(InvalidOperationException("Taken."), down, "Not signed").text, "Taken.")
        XCTAssertEqual(CertificatesModel.failure(CocoaError(.fileReadUnknown), down, "Not signed").title, "Something went wrong")
    }
}
#endif
