import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageImportEncryptedTests.cs: the same cases. The key material comes from a seeded
// generator, as the Crypt tests do.

final class PageImportEncryptedTests: XCTestCase {
    private let fileId = (1...16).map { UInt8($0) }

    private func secure(_ strength: PdfCryptStrength) -> PdfSecurity {
        PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .all, strength: strength, firstId: fileId,
                           random: SeededRandom(7))
    }

    private func encrypt(_ plain: [UInt8], _ strength: PdfCryptStrength) throws -> [UInt8] {
        try PdfDocument.open(plain).saveRewrite(PdfSaveOptions(useObjectStreams: false, security: secure(strength), documentId: fileId))
    }

    private func shows(_ file: [UInt8], _ text: String) -> Bool {
        TestPdf.contains(file, text)
    }

    func test_pagesOfAnEncryptedSourceComeAcrossReadable() throws {
        for strength in [PdfCryptStrength.aes128, .aes256] {
            let source = try PdfDocument.open(try encrypt(PageImportTests.source(), strength))
            XCTAssertTrue(source.isEncrypted, "\(strength)")
            let target = try PageTestFiles.open(1)
            try PageOperations.importPages(target, source, [0, 1], 1)
            XCTAssertEqual(PageTestFiles.order(target), [1, 11, 12], "\(strength)")
            let again = try PdfDocument.open(try target.saveRewrite())
            XCTAssertFalse(again.isEncrypted, "\(strength)")
            let images = again.objectNumbers.compactMap { again.get($0) as? PdfStream }.filter { again.name($0.dictionary, "Subtype") == "Image" }
            XCTAssertEqual(images.count, 1, "\(strength)")
            XCTAssertEqual(try images.first.map { try again.data($0) }, [0x80], "\(strength)")
            XCTAssertEqual(try PageTestFiles.reopen(target), ["Page 1", "Page 11", "Page 12"], "\(strength)")
        }
    }

    func test_formValuesOfAnEncryptedSourceComeAcrossAsText() throws {
        let source = try PdfDocument.open(try encrypt(formSource(), .aes256))
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, source, [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let first = try XCTUnwrap(again.array(again.dict(again.catalog, "AcroForm"), "Fields")).items[0]
        let field = try XCTUnwrap(again.resolve(first) as? PdfDictionary)
        XCTAssertEqual(PageTestFiles.text(field["V"]), "Alice")
    }

    private func formSource() -> [UInt8] {
        PageImportTests.source("/Annots [50 0 R]", "/AcroForm <</Fields [50 0 R]>>", { pdf in
            pdf.obj(50, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Alice) /Rect [0 0 50 20]>>")
        })
    }

    func test_pagesGoIntoAnEncryptedTargetAndAreEncryptedWithIt() throws {
        for strength in [PdfCryptStrength.aes128, .aes256] {
            let target = try PdfDocument.open(try encrypt(PageTestFiles.make(1), strength))
            try PageOperations.importPages(target, try PdfDocument.open(PageImportTests.source()), [0], 1)
            let saved = try target.saveRewrite(PdfSaveOptions(useObjectStreams: true, security: target.security))
            XCTAssertFalse(shows(saved, "Page 11"), "\(strength)")
            let again = try PdfDocument.open(saved)
            XCTAssertTrue(again.isEncrypted, "\(strength)")
            XCTAssertEqual(PageTestFiles.order(again), [1, 11], "\(strength)")
        }
    }

    func test_anEncryptedFileTakesPagesInASession() throws {
        let session = try PdfEditSession.open(try encrypt(PageTestFiles.make(2), .aes256))
        let source = try PdfDocument.open(try encrypt(PageImportTests.source(), .aes128))
        try PageOperations.importPages(session.document, source, [0, 2], 1)
        XCTAssertTrue(try session.commit("Insert pages"))
        XCTAssertFalse(shows(session.current, "Page 11"))
        let reopened = try PdfDocument.open(session.current)
        XCTAssertEqual(PageTestFiles.order(reopened), [1, 11, 13, 2])
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(PageTestFiles.order(session.document), [1, 2])
    }

    func test_aDeleteAndAMoveInAnEncryptedFileReadBack() throws {
        let session = try PdfEditSession.open(try encrypt(PageTestFiles.make(4), .aes256))
        try PageOperations.delete(session.document, [0])
        try PageOperations.move(session.document, [0], 3)
        XCTAssertTrue(try session.commit("Edit"))
        XCTAssertEqual(PageTestFiles.order(try PdfDocument.open(session.current)), [3, 4, 2])
    }
}
