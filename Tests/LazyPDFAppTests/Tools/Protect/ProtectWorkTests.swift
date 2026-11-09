import XCTest
import LazyPDFKit
#if canImport(Security)
import Security
#endif
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/protect/ProtectWorkTests.cs. The tests with certificates need the system's Security
// framework and are left out where it is missing.

@MainActor
final class ProtectWorkTests: XCTestCase {
    private func plain(_ pages: Int = 2) throws -> PdfDocument {
        try PdfDocument.open(Pdfs.text(pages))
    }

    private func protected(_ open: String, _ owner: String, _ allowed: PdfPermissions = .all, _ strength: PdfCryptStrength = .aes256,
                           pages: Int = 2) throws -> [UInt8] {
        try ProtectWork.withPassword(plain(pages), openPassword: open, ownerPassword: owner, allowed: allowed, strength: strength)
    }

    private nonisolated func problem(_ error: Error) -> PdfReadProblem? {
        (error as? PdfReadException)?.problem
    }

    func test_aPasswordOpensTheCopyAndNothingElseDoes() throws {
        for (strength, revision) in [(PdfCryptStrength.aes256, 6), (.aes128, 4)] {
            let bytes = try protected("open sesame", "open sesame", .all, strength, pages: 3)

            let opened = try PdfDocument.open(bytes, password: "open sesame")
            XCTAssertEqual(opened.pages.count, 3)
            XCTAssertEqual(opened.security?.revision, revision)
            XCTAssertThrowsError(try PdfDocument.open(bytes, password: "wrong")) { XCTAssertEqual(self.problem($0), .passwordRequired) }
            XCTAssertThrowsError(try PdfDocument.open(bytes)) { XCTAssertEqual(self.problem($0), .passwordRequired) }
        }
    }

    func test_limitsWithoutAPasswordToOpenLetAnyoneReadButNotDoMore() throws {
        var choices = PermissionChoices.everything
        choices.copy = false
        choices.edit = false
        choices.print = false
        let allowed = choices.toPermissions()

        let bytes = try protected("", "boss", allowed)

        let reader = try PdfDocument.open(bytes)
        XCTAssertFalse(reader.security!.openedAsOwner)
        XCTAssertEqual(reader.security!.permissions.intersection([.copy, .modify, .print, .printHighQuality]), .none)
        XCTAssertTrue(reader.security!.permissions.contains(.annotate))
        XCTAssertTrue(try PdfDocument.open(bytes, password: "boss").security!.openedAsOwner)
    }

    func test_highQualityPrintingNeedsPrintingToBeAllowed() {
        var noPrint = PermissionChoices.everything
        noPrint.print = false

        XCTAssertFalse(noPrint.toPermissions().contains(.printHighQuality))
        XCTAssertTrue(PermissionChoices.everything.toPermissions().contains(.printHighQuality))
        XCTAssertEqual(PermissionChoices.everything.toPermissions(), .all)
    }

    func test_protectionComesOffAgainWhenTheOwnerHoldsIt() throws {
        let locked = try protected("secret", "secret")
        let document = try PdfDocument.open(locked, password: "secret")

        let open = try ProtectWork.remove(document)

        let back = try PdfDocument.open(open)
        XCTAssertFalse(back.isEncrypted)
        XCTAssertEqual(back.pages.count, 2)
    }

    func test_aRestrictedFileOpenedWithoutTheOwnerPasswordCannotBeRewritten() throws {
        let document = try PdfDocument.open(Pdfs.restricted(.print))

        XCTAssertTrue(ProtectWork.isLockedAgainstChange(document))
        XCTAssertThrowsError(try ProtectWork.remove(document)) { XCTAssertTrue($0 is PdfPermissionException) }
        XCTAssertThrowsError(try ProtectWork.withPassword(document, openPassword: "new", ownerPassword: "new", allowed: .all, strength: .aes256)) {
            XCTAssertTrue($0 is PdfPermissionException)
        }
    }

    func test_theOwnerPasswordLiftsTheLock() throws {
        let document = try PdfDocument.open(Pdfs.restricted(.print), password: "owner")

        XCTAssertFalse(ProtectWork.isLockedAgainstChange(document))
        XCTAssertFalse(try PdfDocument.open(ProtectWork.remove(document)).isEncrypted)
    }

    func test_aFileThatRestrictsNothingIsNotLocked() throws {
        XCTAssertFalse(ProtectWork.isLockedAgainstChange(try PdfDocument.open(Pdfs.restricted(.all))))
        XCTAssertFalse(ProtectWork.isLockedAgainstChange(try plain()))
    }

    func test_protectingAgainReplacesTheOldPassword() throws {
        let first = try protected("one", "one")
        let document = try PdfDocument.open(first, password: "one")

        let second = try ProtectWork.withPassword(document, openPassword: "two", ownerPassword: "two", allowed: .all, strength: .aes256)

        XCTAssertThrowsError(try PdfDocument.open(second, password: "one"))
        XCTAssertEqual(try PdfDocument.open(second, password: "two").pages.count, 2)
    }

    func test_addingCommentsAlwaysAllowsFillingFormsAndReadingAloudIsNeverSwitchedOff() {
        var withComment = PermissionChoices.everything
        withComment.fillForms = false
        var noComment = withComment
        noComment.comment = false

        XCTAssertTrue(withComment.toPermissions().contains(.fillForms))
        XCTAssertFalse(noComment.toPermissions().contains(.fillForms))
        XCTAssertTrue(noComment.toPermissions().contains(.extractForAccessibility))
    }

    func test_thePasswordBoxesMustAgreeBeforeAnythingRuns() {
        let cases: [(String, String, Bool, String, Bool)] = [
            ("", "", false, "", false), ("a", "a", false, "", true), ("a", "b", false, "", false), ("", "", true, "boss", true),
            ("", "", true, "", false), ("a", "a", true, "a", false), ("a", "a", true, "b", true),
        ]
        for (open, repeated, limited, owner, expected) in cases {
            XCTAssertEqual(ProtectWork.passwordsAgree(open, repeated, limited: limited, owner: owner), expected, "\(open) \(repeated) \(limited) \(owner)")
        }
    }

    func test_aProtectedCopyAsksForItsPasswordAndThenOpensAsADocumentThatNeedsAName() async throws {
        let f = ViewModelFixture(self)
        let bytes = try protected("secret", "secret")

        await f.vm.openNew(bytes, title: "a protected.pdf")
        XCTAssertNotNil(f.vm.passwordRequest)
        await f.vm.submitPassword("secret")

        let tab = try XCTUnwrap(f.vm.activeDocument)
        XCTAssertEqual(tab.pageCount, 2)
        XCTAssertTrue(tab.document.isEncrypted)
        XCTAssertTrue(AppViewModel.needsName(tab))
    }

    #if canImport(Security)
    private func made(_ name: String) throws -> X509Certificate {
        try PdfDigitalId.create(name, nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 20, keyBits: 2048)
    }

    private func withKey(_ certificate: X509Certificate) throws -> Recipient {
        try XCTUnwrap(Recipient(try XCTUnwrap(PdfCertificate(certificate))))
    }

    private func withoutKey(_ certificate: X509Certificate) throws -> Recipient {
        let sec = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(certificate.rawData) as CFData))
        return try XCTUnwrap(Recipient(PdfCertificate(certificate: sec)))
    }

    func test_aCertificateHolderOpensTheCopy() throws {
        let mine = try withKey(made("Me"))
        let theirs = try withoutKey(made("Them"))

        let (bytes, opener) = try ProtectWork.forRecipients(plain(2), [mine.toPdfRecipient(.all), theirs.toPdfRecipient(.print)], .aes256)

        XCTAssertEqual(opener.flatMap { Recipient($0)?.thumbprint }, mine.thumbprint)
        let opened = try PdfDocument.open(bytes, certificate: try XCTUnwrap(opener))
        XCTAssertEqual(opened.pages.count, 2)
        XCTAssertTrue(opened.security!.isPublicKey)
        XCTAssertTrue(opened.security!.openedAsOwner)
        XCTAssertThrowsError(try PdfDocument.open(bytes, password: "password")) { XCTAssertEqual(self.problem($0), .certificateRequired) }
    }

    func test_aCopyForOthersOnlyHasNoOneToOpenItHere() throws {
        let theirs = try withoutKey(made("Them"))

        let (bytes, opener) = try ProtectWork.forRecipients(plain(2), [theirs.toPdfRecipient(.all)], .aes256)

        XCTAssertNil(opener)
        XCTAssertFalse(bytes.isEmpty)
    }

    func test_onlyTheHolderOfAKeyOnThisComputerMayChangeTheProtectionLater() throws {
        let mine = try withKey(made("Me"))
        let theirs = try withoutKey(made("Them"))

        XCTAssertTrue(mine.toPdfRecipient(.print).canChangeEncryption)
        XCTAssertFalse(theirs.toPdfRecipient(.print).canChangeEncryption)
    }
    #endif
}
