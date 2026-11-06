import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeStructureTests.cs: the same cases (comments and hidden-layer
// annotations that a structure tree still points at, and encryption). The PdfPig page count of the first test has no
// twin; the engine's own stands in for it. The C# seeds the key generator with System.Random(3); here it is SeededRandom.

final class SanitizeStructureTests: XCTestCase {
    private func tagged(_ annotExtra: String = "", _ catalogExtra: String = "") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /MarkInfo <</Marked true>> /StructTreeRoot 7 0 R \(catalogExtra)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [5 0 R] /StructParents 1>>")
        pdf.stream(4, "", "0 g 10 10 20 20 re f")
        pdf.obj(5, "<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /T (MARKERWHO) /Contents (MARKERNOTE) /StructParent 0 \(annotExtra)>>")
        pdf.obj(7, "<</Type /StructTreeRoot /K 8 0 R /ParentTree 9 0 R>>")
        pdf.obj(8, "<</Type /StructElem /S /Annot /P 7 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 5 0 R /Pg 3 0 R>>>>")
        pdf.obj(9, "<</Nums [0 8 0 R]>>")
        pdf.obj(10, "<</Type /OCG /Name (Off)>>")
        return pdf.finish()
    }

    func test_aCommentThatTheStructureTreeReachesIsGone() throws {
        let file = tagged()
        XCTAssertTrue(try OptimizeKit.everywhere(file, "MARKERNOTE"))
        let document = try PdfDocument.open(file)
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERNOTE"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERWHO"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .comments))
        XCTAssertEqual(1, try PdfDocument.open(result.bytes).pages.count)
    }

    func test_thePlaceOfARemovedCommentInTheStructureTreeIsGoneToo() throws {
        let document = try PdfDocument.open(tagged())
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "OBJR"))
    }

    func test_anAnnotationOfAHiddenLayerThatTheStructureTreeReachesIsGone() throws {
        let file = tagged("/OC 10 0 R", "/OCProperties <</OCGs [10 0 R] /D <</OFF [10 0 R]>>>>")
        let document = try PdfDocument.open(file)
        let result = try PdfSanitizer(document).run(SanitizeOptions(comments: false))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERNOTE"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .hiddenLayers))
    }

    private let fileId = (1...16).map { UInt8($0) }

    private func encrypted(_ permissions: PdfPermissions, _ strength: PdfCryptStrength = .aes256) throws -> [UInt8] {
        let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: permissions, strength: strength, firstId: fileId, random: SeededRandom(3))
        return try PdfDocument.open(TestPdf.simple(2)).saveRewrite(PdfSaveOptions(security: security, documentId: fileId))
    }

    func test_anEncryptedFileKeepsItsEncryptionByDefault() throws {
        let document = try PdfDocument.open(try encrypted(.all), password: "user")
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        assertReadFails(try PdfDocument.open(result.bytes), .passwordRequired)
        let again = try PdfDocument.open(result.bytes, password: "user")
        XCTAssertTrue(again.isEncrypted)
        XCTAssertEqual(2, again.pages.count)
    }

    func test_aGivenIdDoesNotBreakTheKeptHandler() throws {
        for strength in PdfCryptStrength.allCases {
            let document = try PdfDocument.open(try encrypted(.all, strength), password: "user")
            let result = try PdfSanitizer(document).run(SanitizeOptions(documentId: (40..<56).map { UInt8($0) }))
            let again = try PdfDocument.open(result.bytes, password: "user")
            XCTAssertEqual(2, again.pages.count, "\(strength)")
        }
    }

    func test_aHandlerPassedInTheOptionsKeepsTheFileOpenable() throws {
        for strength in PdfCryptStrength.allCases {
            let document = try PdfDocument.open(try encrypted(.all, strength), password: "user")
            let result = try PdfSanitizer(document).run(SanitizeOptions(security: document.security))
            let again = try PdfDocument.open(result.bytes, password: "user")
            XCTAssertEqual(2, again.pages.count, "\(strength)")
        }
    }

    func test_encryptionCanBeDroppedOnRequest() throws {
        let document = try PdfDocument.open(try encrypted(.all), password: "user")
        let result = try PdfSanitizer(document).run(SanitizeOptions(keepEncryption: false))
        let again = try PdfDocument.open(result.bytes)
        XCTAssertFalse(again.isEncrypted)
    }
}
