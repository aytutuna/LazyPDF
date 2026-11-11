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

    private func withGlobals() -> [UInt8] {
        let security = LinearizerKit.secure(.aes128)
        let pdf = TestPdf("%PDF-1.6\n")
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Extra 6 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 50 50]>>")
        pdf.stream(6, "/Filter [/Crypt /JBIG2Decode] /DecodeParms [<</Name /Identity>> <</JBIG2Globals 9 0 R>>]", TestPdf.latin("HELLO"))
        pdf.stream(9, "", security.encryptStream(9, 0, TestPdf.latin("globals"), PdfDictionary()))
        pdf.obj(8, security.dictionary.description)
        let id = Hex.string(LinearizerKit.fileId)
        return pdf.finish("/Root 1 0 R /Encrypt 8 0 R /ID [<\(id)> <\(id)>]")
    }

    func test_aStreamWithACryptStageKeepsItsParameterReferencesUnderANewHandler() throws {
        for user in ["", "other"] {
            let source = try PdfDocument.open(withGlobals())
            let options = user.isEmpty ? PdfSaveOptions() : PdfSaveOptions(security: LinearizerKit.secure(.aes256, user))
            let file = try source.saveLinearized(options)
            let password: String? = user.isEmpty ? nil : user
            try LinearizerKit.verify(file, password)
            let again = try PdfDocument.open(file, password: password)
            let extra = try XCTUnwrap(again.resolve(again.catalog["Extra"]) as? PdfStream)
            let filters = try XCTUnwrap(again.resolve(extra.dictionary["Filter"]) as? PdfArray)
            XCTAssertEqual(1, filters.items.count)
            XCTAssertEqual("JBIG2Decode", (filters.items[0] as? PdfName)?.value)
            let list = try XCTUnwrap(again.resolve(extra.dictionary["DecodeParms"]) as? PdfArray)
            XCTAssertEqual(1, list.items.count)
            let parameters = try XCTUnwrap(again.resolve(list.items[0]) as? PdfDictionary)
            let globals = try XCTUnwrap(again.resolve(parameters["JBIG2Globals"]) as? PdfStream)
            XCTAssertEqual("globals", TestPdf.text(again.rawData(globals)), "\(user)")
        }
    }
}
