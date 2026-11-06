import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/LinearizerEncryptionTests.cs: the same cases. PdfPig text comparisons have
// no twin; the engine's own text stands in for them.

final class LinearizerEncryptionTests: XCTestCase {
    private func encrypted(_ strength: PdfCryptStrength, _ user: String = "") throws -> [UInt8] {
        let security = LinearizerKit.secure(strength, user)
        return try PdfDocument.open(LinearizerKit.make(5)).saveRewrite(PdfSaveOptions(security: security, documentId: LinearizerKit.fileId))
    }

    func test_anEncryptedFileStaysEncryptedUnderItsOwnHandler() throws {
        for strength in [PdfCryptStrength.aes256, .aes128] {
            let source = try PdfDocument.open(try encrypted(strength))
            let file = LinearizerKit.keep("encrypted-\(strength)", try source.saveLinearized(PdfSaveOptions(security: source.security)))
            try LinearizerKit.verify(file)
            let again = try PdfDocument.open(file)
            XCTAssertTrue(again.isEncrypted)
            XCTAssertEqual(source.pages.map { $0.contents().count }, again.pages.map { $0.contents().count })
            XCTAssertEqual(LinearizerKit.textText(source), LinearizerKit.textText(again), "\(strength)")
            XCTAssertEqual(source.id[0], again.id[0])
        }
    }

    func test_withoutAHandlerTheOutputIsOpen() throws {
        let source = try PdfDocument.open(try encrypted(.aes256))
        let file = try source.saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertFalse(again.isEncrypted)
        XCTAssertEqual(source.pages[3].contents(), again.pages[3].contents())
    }

    func test_aNewHandlerLocksAnOpenFileWithItsPassword() throws {
        let security = LinearizerKit.secure(.aes256, "user")
        let file = try PdfDocument.open(LinearizerKit.make(4)).saveLinearized(PdfSaveOptions(security: security))
        assertReadFails(try PdfDocument.open(file), .passwordRequired)
        try LinearizerKit.verify(file, "user")
        let again = try PdfDocument.open(file, password: "user")
        XCTAssertEqual(4, again.pages.count)
    }

    func test_theEncryptionDictionaryStaysInTheFirstSection() throws {
        let source = try PdfDocument.open(try encrypted(.aes256))
        let file = try source.saveLinearized(PdfSaveOptions(security: source.security))
        let parameters = try LinearizerKit.verify(file)
        let text = Latin1.string(file)
        let at = OptimizeKit.indexOf(file, Latin1.bytes("/Encrypt "))
        XCTAssertTrue(at >= 1 && at <= (parameters["H0"] ?? 0))
        XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains("/Filter/Standard"))
    }

    func test_aRestrictedFileNeedsTheOwnerToLoseItsEncryption() throws {
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .print, strength: .aes256, firstId: LinearizerKit.fileId, random: SeededRandom(1))
        let locked = try PdfDocument.open(LinearizerKit.make(2)).saveRewrite(PdfSaveOptions(security: security, documentId: LinearizerKit.fileId))
        let asUser = try PdfDocument.open(locked)
        XCTAssertThrowsError(try asUser.saveLinearized()) { XCTAssertTrue($0 is PdfPermissionException, "\($0)") }
        try LinearizerKit.verify(try asUser.saveLinearized(PdfSaveOptions(security: asUser.security)))
        let asOwner = try PdfDocument.open(locked, password: "owner")
        try LinearizerKit.verify(try asOwner.saveLinearized())
    }
}
