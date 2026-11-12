import XCTest
import LazyPDFKit
#if canImport(Security)
import Security
#endif
@testable import LazyPDFApp

// The Protect panel as the window drives it. Windows has no test of the panel itself; its pieces are tested with
// ProtectWorkTests, PasswordStrengthTests and RecipientSourceTests.

@MainActor
final class ProtectModelTests: XCTestCase {
    private func attached(_ bytes: [UInt8]? = nil, password: String? = nil) throws -> (model: ProtectModel, rig: SecurityRig) {
        let rig = try SecurityRig(bytes, password: password)
        let model = ProtectModel()
        rig.attach(model)
        return (model, rig)
    }

    private func protectedFile(_ password: String) throws -> [UInt8] {
        try ProtectWork.withPassword(PdfDocument.open(Pdfs.text(2)), openPassword: password, ownerPassword: password, allowed: .all, strength: .aes256)
    }

    func test_theButtonWaitsForTwoPasswordsThatAgree() async throws {
        let (model, _) = try attached()
        XCTAssertFalse(model.action!.canRun())

        model.openPassword = "secret"
        XCTAssertFalse(model.action!.canRun())
        model.repeatPassword = "secrex"
        XCTAssertEqual(model.passwordNote, "The passwords do not match.")
        XCTAssertFalse(model.action!.canRun())
        model.repeatPassword = "secret"

        XCTAssertEqual(model.passwordNote, "")
        XCTAssertTrue(model.action!.canRun())
    }

    func test_aPasswordRunOpensAProtectedCopyWithThePasswordAndClearsTheBoxes() async throws {
        let (model, rig) = try attached()
        model.openPassword = "secret"
        model.repeatPassword = "secret"

        await model.action!.run()

        let made = try XCTUnwrap(rig.host.openedNew.first)
        XCTAssertEqual(made.title, "a protected.pdf")
        XCTAssertEqual(made.password, "secret")
        XCTAssertNil(made.certificate)
        XCTAssertEqual(try PdfDocument.open(made.pdf, password: "secret").pages.count, 2)
        XCTAssertThrowsError(try PdfDocument.open(made.pdf))
        XCTAssertEqual(model.openPassword, "")
        XCTAssertEqual(model.repeatPassword, "")
        XCTAssertEqual(rig.host.notices.first?.title, "Copy with protection")
        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_limitsNeedAPermissionsPasswordThatDiffersFromTheOneToOpen() async throws {
        let (model, _) = try attached()
        model.limited = true
        model.openPassword = "same"
        model.repeatPassword = "same"
        XCTAssertEqual(model.ownerNote, "Type a Permissions password to apply the limits.")
        XCTAssertFalse(model.action!.canRun())

        model.ownerPassword = "same"
        XCTAssertEqual(model.ownerNote, "Use a different password here.")
        XCTAssertFalse(model.action!.canRun())

        model.ownerPassword = "boss"
        XCTAssertEqual(model.ownerNote, "")
        XCTAssertTrue(model.action!.canRun())
    }

    func test_detachingClearsEveryPasswordTheBoxesHeld() async throws {
        let (model, _) = try attached()
        model.openPassword = "one"
        model.repeatPassword = "one"
        model.ownerPassword = "two"
        model.unlockPassword = "three"

        model.detach()

        XCTAssertEqual([model.openPassword, model.repeatPassword, model.ownerPassword, model.unlockPassword], ["", "", "", ""])
    }

    func test_removeIsOnlyForAProtectedFileAndFallsBackWhenTheFileIsNot() async throws {
        let (model, rig) = try attached()
        model.mode = .remove
        model.detach()
        model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertEqual(model.mode, .password)
        XCTAssertFalse(model.isEncrypted)
        XCTAssertEqual(model.stateNote, "This file is not protected.")

        let (locked, lockedRig) = try attached(try protectedFile("secret"), password: "secret")
        locked.mode = .remove
        XCTAssertTrue(locked.isEncrypted)
        XCTAssertEqual(locked.stateNote, "Protected with a password.")
        XCTAssertTrue(locked.action!.canRun())

        await locked.action!.run()

        let made = try XCTUnwrap(lockedRig.host.openedNew.first)
        XCTAssertEqual(made.title, "a unprotected.pdf")
        XCTAssertFalse(try PdfDocument.open(made.pdf).isEncrypted)
        XCTAssertNil(made.password)
        XCTAssertEqual(lockedRig.host.statuses.last, "Protection removed from a copy.")
    }

    func test_aFileWithLimitsAsksForThePermissionsPasswordAndRefusesAWrongOne() async throws {
        let (model, rig) = try attached(try Pdfs.restricted(.print), password: "")
        model.openPassword = "new"
        model.repeatPassword = "new"

        XCTAssertTrue(model.locked)
        XCTAssertTrue(model.asksForUnlock)
        XCTAssertEqual(model.stateNote, "Opened with limited rights. Enter its permissions password to change the protection.")
        XCTAssertFalse(model.action!.canRun())

        model.unlockPassword = "guess"
        XCTAssertTrue(model.action!.canRun())
        await model.action!.run()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Wrong password"])
        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(model.openPassword, "new")

        model.unlockPassword = "owner"
        await model.action!.run()

        let made = try XCTUnwrap(rig.host.openedNew.first)
        XCTAssertEqual(try PdfDocument.open(made.pdf, password: "new").pages.count, 1)
        XCTAssertEqual(model.unlockPassword, "")
    }

    func test_aSignedFileAndAPdfACopyAreWarnedAbout() async throws {
        let (model, _) = try attached(try Pdfs.signed(certified: false))

        XCTAssertEqual(model.warnNote, "The copy will not keep the signatures.")
    }

    func test_aStrongPasswordIsRatedAndAnOldCipherWarnsAboutWideLetters() async throws {
        let (model, _) = try attached()

        model.openPassword = "Tr0ub4dor&3x"
        XCTAssertEqual(model.strength, .good)
        XCTAssertEqual(model.strengthHint, "Good.")
        model.aes128 = true
        XCTAssertEqual(model.strengthNote, "")
        model.openPassword = "Şifre ğüçlü!"
        XCTAssertEqual(model.strengthNote, "Older readers may not accept these letters. Use AES 256-bit.")
    }

    func test_aCancelledRunLeavesNothingBehind() async throws {
        let (model, rig) = try attached()
        model.openPassword = "secret"
        model.repeatPassword = "secret"
        rig.host.token.cancel()

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.statuses.last, "Canceled.")
    }

    #if canImport(Security)
    private func recipient(_ name: String, key: Bool) throws -> Recipient {
        let made = try PdfDigitalId.create(name, nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 20, keyBits: 2048, encipher: true)
        if key { return try XCTUnwrap(Recipient(try XCTUnwrap(PdfCertificate(made)))) }
        let sec = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(made.rawData) as CFData))
        return try XCTUnwrap(Recipient(PdfCertificate(certificate: sec)))
    }

    func test_aCopyForCertificatesOpensHereForTheRecipientWhoseKeyIsOnThisDevice() async throws {
        let (model, rig) = try attached()
        let mine = try recipient("Me", key: true)
        model.mode = .certificates
        XCTAssertEqual(model.recipientNote, "Add at least one certificate.")
        XCTAssertFalse(model.action!.canRun())
        model.add(mine)
        model.add(mine)
        model.add(try recipient("Them", key: false))

        XCTAssertEqual(model.recipients.count, 2)
        XCTAssertEqual(model.recipientNote, "")
        await model.action!.run()

        let made = try XCTUnwrap(rig.host.openedNew.first)
        XCTAssertEqual(made.certificate?.id, mine.thumbprint)
        XCTAssertNil(made.password)
        XCTAssertThrowsError(try PdfDocument.open(made.pdf)) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .certificateRequired) }
    }

    func test_aCopyForOthersOnlyIsHandedToTheExporterAndTheTemporaryFileGoes() async throws {
        let (model, rig) = try attached()
        model.mode = .certificates
        model.add(try recipient("Them", key: false))
        XCTAssertTrue(model.recipientNote.hasPrefix("None of these has its key"))

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        let sent = try XCTUnwrap(rig.host.exported.first)
        XCTAssertEqual(sent.name, "a protected.pdf")
        XCTAssertFalse(sent.bytes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.host.exportedUrls[0].path))
        XCTAssertEqual(rig.host.notices.first?.title, "Copy for the others")
        XCTAssertEqual(rig.host.statuses.last, "Protected copy saved.")
    }

    func test_aCopyNobodyTookIsNotAnnouncedAsSaved() async throws {
        let (model, rig) = try attached()
        model.mode = .certificates
        model.add(try recipient("Them", key: false))
        rig.host.exportAnswers = false

        await model.action!.run()

        XCTAssertTrue(rig.host.notices.isEmpty)
        XCTAssertTrue(rig.host.statuses.isEmpty)
    }

    func test_aFileThatIsNotACertificateIsReportedByName() async throws {
        let (model, rig) = try attached()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appendingPathComponent("notes.cer")
        try Data("nothing".utf8).write(to: notes)
        let good = folder.appendingPathComponent("ada.cer")
        try Data(PdfDigitalId.create("Ada", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 20, keyBits: 2048, encipher: true).rawData).write(to: good)
        rig.host.picked = [ToolFile(url: notes), ToolFile(url: good)]

        await model.addFromFiles()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Not a usable certificate"])
        XCTAssertTrue(rig.host.problems[0].text.contains("notes.cer"))
        XCTAssertEqual(model.recipients.map(\.name), ["Ada"])
    }
    #endif
}
