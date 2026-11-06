import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/RotatedAndEncryptedTests.cs: the same cases. The theories are tests that
// loop over their cases. The last assertion of EncryptedFilesAreEditedAndStayEncrypted looks for "grand" in the saved
// bytes; the C# builds the text to look for from a Span, whose ToString never holds it, so it can only pass.

final class RotatedAndEncryptedTests: XCTestCase {
    func test_rotatedPagesAreEditedInUserSpace() throws {
        for rotate in [90, 180, 270] {
            let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET", "/Rotate \(rotate)")
            let before = try EditKit.glyphs(session)
            let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand")
            XCTAssertTrue(result.done, "\(rotate): \(result.problem ?? "")")
            XCTAssertTrue(try EditKit.text(session).contains("Hello grand world"), "\(rotate)")
            XCTAssertEqual(Array(before.prefix(6)), Array(try EditKit.glyphs(session).prefix(6)), "\(rotate)")
        }
    }

    func test_textRotatedInTheContentIsEditedAlongItsBaseline() throws {
        let session = try EditKit.session("BT /F1 12 Tf 0 1 -1 0 300 300 Tm (Hello brave world) Tj ET")
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(try EditKit.text(session).contains("Hello grand world"))
        for g in try EditKit.glyphs(session) { XCTAssertEqual(g.x, 300, accuracy: 0.0005) }
    }

    func test_encryptedFilesAreEditedAndStayEncrypted() throws {
        for strength in [PdfCryptStrength.aes256, .aes128] {
            let plain = try PdfDocument.open(EditKit.file("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET"))
            let id = (1...16).map { UInt8($0) }
            let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all, strength: strength, firstId: id)
            let locked = try plain.saveRewrite(PdfSaveOptions(security: security, documentId: id))
            let session = try PdfEditSession.open(locked, password: "user")
            let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand")
            XCTAssertTrue(result.done, "\(strength): \(result.problem ?? "")")
            let reopened = try PdfDocument.open(session.current, password: "user")
            XCTAssertTrue(reopened.isEncrypted)
            XCTAssertTrue(TextPage.create(reopened, reopened.pages[0]).text.contains("Hello grand world"))
            XCTAssertFalse(TestPdf.contains(session.current, "grand"), "\(strength)")
            XCTAssertTrue(try session.undo())
            XCTAssertTrue(TextPage.create(session.document, session.document.pages[0]).text.contains("brave"))
        }
    }
}
