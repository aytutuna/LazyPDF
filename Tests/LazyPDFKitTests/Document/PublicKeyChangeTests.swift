#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Crypt/PublicKeyChangeTests.cs: the same cases, except that
// OwnerRemovesEncryptionFromBothKinds leaves out the PdfPig read of the result (the engine's own read stays).
// It sits in the Document layer's folder because every case opens a PdfDocument.

final class PublicKeyChangeTests: XCTestCase {
    private static let id = [UInt8](repeating: 0, count: 16)

    private func passworded(_ strength: PdfCryptStrength = .aes256) throws -> [UInt8] {
        let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .print, strength: strength, firstId: Self.id)
        return try PdfDocument.open(PublicKeyFiles.plain()).saveRewrite(PdfSaveOptions(security: security, documentId: Self.id))
    }

    private func toRecipients(_ recipients: [PdfRecipient]) throws -> PdfSaveOptions {
        PdfSaveOptions(security: try PdfSecurity.createPublicKey(recipients, .aes256))
    }

    private func toPassword() -> PdfSaveOptions {
        PdfSaveOptions(security: PdfSecurity.create(userPassword: "new", ownerPassword: "newowner", permissions: .all, strength: .aes256, firstId: Self.id),
                       documentId: Self.id)
    }

    private func assertPermissionFails<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { XCTAssertTrue($0 is PdfPermissionException, "\($0)", file: file, line: line) }
    }

    func test_ownerMovesAPasswordFileToCertificates() throws {
        for strength in [PdfCryptStrength.aes256, .aes128] {
            let owner = try PdfDocument.open(passworded(strength), password: "owner")

            let moved = try owner.saveRewrite(toRecipients([PdfRecipient(PublicKeyFiles.alice)]))

            let document = try PdfDocument.open(moved, certificate: PublicKeyFiles.alice)
            XCTAssertEqual(document.security?.isPublicKey, true, "\(strength)")
            XCTAssertTrue(PublicKeyFiles.content(document).contains(PublicKeyFiles.pageText), "\(strength)")
            assertReadFails(try PdfDocument.open(moved, password: "owner"), .certificateRequired)
        }
    }

    func test_ownerMovesACertificateFileToAPassword() throws {
        let owner = try PdfDocument.open(PublicKeyFiles.seal([PdfRecipient(PublicKeyFiles.alice, canChangeEncryption: true)]),
                                         certificate: PublicKeyFiles.alice)

        let moved = try owner.saveRewrite(toPassword())

        let document = try PdfDocument.open(moved, password: "new")
        XCTAssertEqual(document.security?.isPublicKey, false)
        XCTAssertTrue(PublicKeyFiles.content(document).contains(PublicKeyFiles.pageText))
    }

    func test_ownerRemovesEncryptionFromBothKinds() throws {
        let password = try PdfDocument.open(passworded(), password: "owner")
        let certificate = try PdfDocument.open(PublicKeyFiles.seal([PdfRecipient(PublicKeyFiles.alice, canChangeEncryption: true)]),
                                               certificate: PublicKeyFiles.alice)

        for open in [password, certificate] {
            let plain = try open.saveRewrite()

            let document = try PdfDocument.open(plain)
            XCTAssertFalse(document.isEncrypted)
            XCTAssertTrue(PublicKeyFiles.content(document).contains(PublicKeyFiles.pageText))
        }
    }

    func test_ownerChangesTheRecipientList() throws {
        let owner = try PdfDocument.open(PublicKeyFiles.seal([PdfRecipient(PublicKeyFiles.alice, canChangeEncryption: true)]),
                                         certificate: PublicKeyFiles.alice)

        let moved = try owner.saveRewrite(toRecipients([PdfRecipient(PublicKeyFiles.bob)]))

        let bob = try PdfDocument.open(moved, certificate: PublicKeyFiles.bob)
        XCTAssertTrue(PublicKeyFiles.content(bob).contains(PublicKeyFiles.pageText))
        assertReadFails(try PdfDocument.open(moved, certificate: PublicKeyFiles.alice), .certificateRequired)
    }

    func test_plainFileMayBeEncryptedByAnyone() throws {
        let plain = try PdfDocument.open(PublicKeyFiles.plain())

        let document = try PdfDocument.open(plain.saveRewrite(toRecipients([PdfRecipient(PublicKeyFiles.alice)])), certificate: PublicKeyFiles.alice)

        XCTAssertTrue(document.isEncrypted)
    }

    func test_userPasswordCannotChangeTheEncryption() throws {
        let user = try PdfDocument.open(passworded(), password: "user")

        XCTAssertEqual(user.security?.openedAsOwner, false)
        assertPermissionFails(try user.saveRewrite())
        assertPermissionFails(try user.saveRewrite(toPassword()))
        assertPermissionFails(try user.saveRewrite(toRecipients([PdfRecipient(PublicKeyFiles.alice)])))
    }

    func test_recipientWithoutOwnershipCannotChangeTheEncryption() throws {
        let recipient = try PdfDocument.open(PublicKeyFiles.seal([PdfRecipient(PublicKeyFiles.alice, permissions: .print)]),
                                             certificate: PublicKeyFiles.alice)

        assertPermissionFails(try recipient.saveRewrite())
        assertPermissionFails(try recipient.saveRewrite(toPassword()))
        assertPermissionFails(try recipient.saveRewrite(toRecipients([PdfRecipient(PublicKeyFiles.bob)])))
    }

    func test_readerWithAllPermissionsMayChangeItBothWays() throws {
        let recipient = try PdfDocument.open(PublicKeyFiles.seal(PublicKeyFiles.alice), certificate: PublicKeyFiles.alice)
        let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all, strength: .aes256, firstId: Self.id)
        let user = try PdfDocument.open(PdfDocument.open(PublicKeyFiles.plain()).saveRewrite(PdfSaveOptions(security: security, documentId: Self.id)),
                                        password: "user")

        XCTAssertFalse(try PdfDocument.open(recipient.saveRewrite()).isEncrypted)
        let moved = try PdfDocument.open(user.saveRewrite(toRecipients([PdfRecipient(PublicKeyFiles.bob)])), certificate: PublicKeyFiles.bob)
        XCTAssertEqual(moved.security?.openedAsOwner, false)
    }

    func test_keepingTheFilesOwnHandlerIsAlwaysAllowed() throws {
        let user = try PdfDocument.open(passworded(), password: "user")
        let recipient = try PdfDocument.open(PublicKeyFiles.seal([PdfRecipient(PublicKeyFiles.alice, permissions: .print)]),
                                             certificate: PublicKeyFiles.alice)

        let again = try PdfDocument.open(user.saveRewrite(PdfSaveOptions(security: user.security)), password: "user")
        let sealedAgain = try PdfDocument.open(recipient.saveRewrite(PdfSaveOptions(useObjectStreams: true, security: recipient.security)),
                                               certificate: PublicKeyFiles.alice)

        XCTAssertTrue(PublicKeyFiles.content(again).contains(PublicKeyFiles.pageText))
        XCTAssertTrue(PublicKeyFiles.content(sealedAgain).contains(PublicKeyFiles.pageText))
    }

    func test_refusedSaveWritesNothingAndLeavesTheDocumentUsable() throws {
        let user = try PdfDocument.open(passworded(), password: "user")

        assertPermissionFails(try user.saveRewrite())

        XCTAssertTrue(PublicKeyFiles.content(user).contains(PublicKeyFiles.pageText))
    }
}
#endif
