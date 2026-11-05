import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/StructureFactsTests.cs: the same cases.

final class StructureFactsTests: XCTestCase {
    func test_plainFile() throws {
        let bytes = TestPdf.simple(3)
        let facts = DocumentFacts.read(try PdfDocument.open(bytes))
        XCTAssertEqual(facts.version, "1.4")
        XCTAssertEqual(facts.fileSize, bytes.count)
        XCTAssertEqual(facts.pageCount, 3)
        XCTAssertEqual(facts.firstPageWidth, 200)
        XCTAssertEqual(facts.firstPageHeight, 300)
        XCTAssertFalse(facts.isEncrypted || facts.isSigned || facts.isCertified || facts.isTagged || facts.hasJavaScript || facts.hasBookmarks || facts.isPortfolio)
        XCTAssertNil(facts.permissions)
        XCTAssertEqual(facts.form, FormKind.none)
        XCTAssertEqual(facts.attachmentCount, 0)
        XCTAssertEqual(facts.layerCount, 0)
        XCTAssertNil(facts.pdfAPart)
        XCTAssertEqual(facts.repairCount, 0)
        XCTAssertNil(facts.metadata.title)
    }

    func test_rotatedFirstPageSwapsTheSize() throws {
        let document = try StructureFixtures.open()
        document.pages[0].dictionary["Rotate"] = PdfNumber(90)
        let facts = DocumentFacts.read(document)
        XCTAssertEqual(facts.firstPageWidth, 300)
        XCTAssertEqual(facts.firstPageHeight, 200)
    }

    func test_documentWithEverything() throws {
        let document = try StructureFixtures.file(
            "/Lang (en) /MarkInfo <</Marked true>> /OpenAction 30 0 R /Outlines 31 0 R /Collection <<>> /AcroForm <</Fields [32 0 R] /SigFlags 3>> "
            + "/OCProperties <</OCGs [33 0 R 34 0 R]>> /Names <</EmbeddedFiles <</Names [(a) 35 0 R]>>>>") { pdf in
            pdf.obj(30, "<</S /JavaScript /JS (1)>>")
            pdf.obj(31, "<</First 36 0 R /Last 36 0 R /Count 1>>")
            pdf.obj(32, "<</FT /Tx /T (f)>>")
            pdf.obj(33, "<</Type /OCG /Name (a)>>")
            pdf.obj(34, "<</Type /OCG /Name (b)>>")
            pdf.stream(37, "", "x")
            pdf.obj(35, "<</F (a.txt) /EF <</F 37 0 R>>>>")
            pdf.obj(36, "<</Title (t)>>")
        }
        let facts = DocumentFacts.read(document)
        XCTAssertTrue(facts.isTagged && facts.isSigned && facts.hasJavaScript && facts.hasBookmarks && facts.isPortfolio)
        XCTAssertEqual(facts.form, .acroForm)
        XCTAssertEqual(facts.attachmentCount, 1)
        XCTAssertEqual(facts.layerCount, 2)
        XCTAssertEqual(facts.language, "en")
    }

    func test_xfaWinsOverAcroForm() throws {
        let document = try StructureFixtures.file("/AcroForm <</Fields [] /XFA [(template) 30 0 R]>>") { $0.stream(30, "", "<x/>") }
        XCTAssertEqual(DocumentFacts.read(document).form, .xfa)
        XCTAssertEqual(DocumentFacts.read(try StructureFixtures.file("/AcroForm <</Fields []>>")).form, FormKind.none)
    }

    func test_encryptedFileShowsPermissions() throws {
        let id = (1...16).map { UInt8($0) }
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: [.print, .copy], strength: .aes256, firstId: id, random: SeededRandom(1))
        let document = try PdfDocument.open(try StructureFixtures.open().saveRewrite(PdfSaveOptions(security: security)))
        let facts = DocumentFacts.read(document)
        XCTAssertTrue(facts.isEncrypted)
        XCTAssertEqual(facts.permissions, [.print, .copy])
    }

    func test_metadataIsIncluded() throws {
        let document = try StructureFixtures.open()
        var metadata = DocumentMetadata.read(document)
        metadata.title = "Plan"
        try metadata.write(document)
        XCTAssertEqual(DocumentFacts.read(document).metadata.title, "Plan")
    }

    func test_noPagesGiveZeroSize() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        let facts = DocumentFacts.read(try PdfDocument.open(pdf.finish()))
        XCTAssertEqual(facts.pageCount, 0)
        XCTAssertEqual(facts.firstPageWidth, 0)
        XCTAssertEqual(facts.firstPageHeight, 0)
    }

    func test_textForFormKinds() {
        XCTAssertEqual(StructureText.formKindName(.none), "None")
        XCTAssertNotEqual(StructureText.formKindName(.acroForm), StructureText.formKindName(.xfa))
    }
}
