import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/AttachmentTests.cs: the same cases. The random bytes of AddListExtractRoundTrip come from
// a seeded generator.

final class AttachmentTests: XCTestCase {
    private let made = DateTimeOffset(2026, 5, 6, 7, 8, 9, offsetMinutes: 120)

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

    func test_addListExtractRoundTrip() throws {
        let document = try StructureFixtures.open()
        let text = Array(String(repeating: "a line of text\n", count: 500).utf8)
        var random = SeededRandom(11)
        let binary = random.bytes(300)
        try PdfAttachments.add(document, "notes.txt", text, mimeType: "text/plain", description: "Meeting notes", created: made, modified: DateTimeOffset(2026, 5, 7, 7, 8, 9, offsetMinutes: 120))
        try PdfAttachments.add(document, "blob.bin", binary)

        let reopened = try StructureFixtures.reopen(document)
        let list = PdfAttachments.list(reopened)
        XCTAssertEqual(list.map { $0.name }, ["blob.bin", "notes.txt"])
        let notes = list[1]
        XCTAssertEqual(notes.fileName, "notes.txt")
        XCTAssertEqual(notes.description, "Meeting notes")
        XCTAssertEqual(notes.mimeType, "text/plain")
        XCTAssertEqual(notes.size, text.count)
        XCTAssertTrue((notes.storedSize ?? Int.max) < text.count)
        XCTAssertEqual(notes.created, made)
        XCTAssertEqual(notes.modified, DateTimeOffset(2026, 5, 7, 7, 8, 9, offsetMinutes: 120))
        XCTAssertEqual(notes.checkSum, hex(Md5.hash(text)))
        XCTAssertNil(notes.pageIndex)
        XCTAssertEqual(try PdfAttachments.extract(reopened, notes), text)
        XCTAssertEqual(try PdfAttachments.extract(reopened, list[0]), binary)
        XCTAssertNil(list[0].mimeType)
        XCTAssertNil(list[0].created)
    }

    func test_extractReadsPastTheDefaultDecodeCap() throws {
        let document = try StructureFixtures.open()
        let big = [UInt8](repeating: 0, count: 300 << 20)
        try PdfAttachments.add(document, "big.bin", big)
        let reopened = try StructureFixtures.reopen(document)
        XCTAssertEqual(try PdfAttachments.extract(reopened, PdfAttachments.list(reopened)[0]).count, big.count)
    }

    func test_emptyFile() throws {
        let document = try StructureFixtures.open()
        try PdfAttachments.add(document, "empty", [])
        let reopened = try StructureFixtures.reopen(document)
        let list = PdfAttachments.list(reopened)
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(try PdfAttachments.extract(reopened, list[0]).isEmpty)
    }

    func test_namesAreMadeUnique() throws {
        let document = try StructureFixtures.open()
        let one = try PdfAttachments.add(document, "a.pdf", [1])
        let two = try PdfAttachments.add(document, "a.pdf", [2])
        let three = try PdfAttachments.add(document, "a.pdf", [3])
        XCTAssertEqual([one, two, three].map { $0.name }, ["a.pdf", "a (2).pdf", "a (3).pdf"])
        XCTAssertEqual(try PdfAttachments.extract(document, two), [2])
    }

    func test_colonsInANameBelongToIt() throws {
        let document = try StructureFixtures.open()
        try PdfAttachments.add(document, "Invoice: March.pdf", [1])
        try PdfAttachments.add(document, "a.b:c", [1])
        XCTAssertEqual(try PdfAttachments.add(document, "Invoice: March.pdf", [2]).name, "Invoice: March (2).pdf")
        XCTAssertEqual(try PdfAttachments.add(document, "a.b:c", [2]).name, "a (2).b:c")
    }

    func test_nonLatinNamesSurvive() throws {
        let document = try StructureFixtures.open()
        try PdfAttachments.add(document, "Журнал.txt", [1], description: "Türkçe")
        let list = PdfAttachments.list(try StructureFixtures.reopen(document))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "Журнал.txt")
        XCTAssertEqual(list[0].description, "Türkçe")
    }

    func test_manyAttachmentsMakeATree() throws {
        let document = try StructureFixtures.open()
        for i in 0..<150 { try PdfAttachments.add(document, String(format: "f%03d.dat", i), [UInt8(i)]) }
        let reopened = try StructureFixtures.reopen(document)
        let list = PdfAttachments.list(reopened)
        XCTAssertEqual(list.count, 150)
        XCTAssertEqual(try PdfAttachments.extract(reopened, list[100]), [100])
    }

    func test_removeFreesTheObjects() throws {
        let document = try StructureFixtures.open()
        let keep = try PdfAttachments.add(document, "keep", [1])
        let drop = try PdfAttachments.add(document, "drop", [2])
        let before = document.objectNumbers.count
        XCTAssertTrue(try PdfAttachments.remove(document, drop))
        XCTAssertEqual(document.objectNumbers.count, before - 2)
        XCTAssertFalse(try PdfAttachments.remove(document, drop))
        let reopened = try StructureFixtures.reopen(document)
        let list = PdfAttachments.list(reopened)
        XCTAssertEqual(list.map { $0.name }, ["keep"])
        XCTAssertEqual(try PdfAttachments.extract(reopened, list[0]), [1])
        XCTAssertEqual(keep.name, "keep")
    }

    func test_removingTheLastOneRemovesTheTree() throws {
        let document = try StructureFixtures.open()
        let only = try PdfAttachments.add(document, "only", [1])
        XCTAssertTrue(try PdfAttachments.remove(document, only))
        XCTAssertNil(document.dict(document.catalog, "Names")?["EmbeddedFiles"])
        XCTAssertTrue(PdfAttachments.list(try StructureFixtures.reopen(document)).isEmpty)
    }

    func test_extractAfterRemoveFails() throws {
        let document = try StructureFixtures.open()
        let item = try PdfAttachments.add(document, "x", [1])
        try PdfAttachments.remove(document, item)
        XCTAssertThrowsError(try PdfAttachments.extract(document, item)) { XCTAssertTrue($0 is InvalidOperationException) }
    }

    private func withAnnotations() throws -> PdfDocument {
        try StructureFixtures.file("", { pdf in
            pdf.stream(30, "/Type /EmbeddedFile /Subtype /application#2Fpdf /Params <</Size 5 /ModDate (D:20260102030405Z)>>", "hello")
            pdf.obj(31, "<</Type /Filespec /F (inner.pdf) /Desc (From a note) /EF <</F 30 0 R>>>>")
            pdf.obj(32, "<</Type /Annot /Subtype /FileAttachment /Rect [10 10 20 20] /Contents (Annotation text) /FS 31 0 R /Name /PushPin>>")
            pdf.obj(33, "<</Type /Filespec /F (outside.pdf)>>")
            pdf.obj(34, "<</Type /Annot /Subtype /FileAttachment /Rect [10 10 20 20] /FS 33 0 R>>")
            pdf.obj(35, "<</Type /Annot /Subtype /Link /Rect [10 10 20 20]>>")
        }, pages: 2)
    }

    func test_listsAttachmentAnnotations() throws {
        let document = try withAnnotations()
        document.pages[1].dictionary["Annots"] = PdfArray([PdfReference(32, 0), PdfReference(34, 0), PdfReference(35, 0)])
        let list = PdfAttachments.list(document)
        XCTAssertEqual(list.count, 1)
        let item = list[0]
        XCTAssertEqual(item.name, "inner.pdf")
        XCTAssertEqual(item.fileName, "inner.pdf")
        XCTAssertEqual(item.description, "From a note")
        XCTAssertEqual(item.pageIndex, 1)
        XCTAssertEqual(item.annotation?.number, 32)
        XCTAssertEqual(item.mimeType, "application/pdf")
        XCTAssertEqual(item.size, 5)
        XCTAssertEqual(item.modified, DateTimeOffset(2026, 1, 2, 3, 4, 5))
        XCTAssertEqual(try PdfAttachments.extract(document, item), Array("hello".utf8))
    }

    func test_annotationNoteIsTheDescriptionWhenTheFileHasNone() throws {
        let document = try withAnnotations()
        (document.get(31) as? PdfDictionary)?.remove("Desc")
        document.pages[0].dictionary["Annots"] = PdfArray([PdfReference(32, 0)])
        XCTAssertEqual(PdfAttachments.list(document).first?.description, "Annotation text")
    }

    func test_removesAnAnnotationAttachment() throws {
        let document = try withAnnotations()
        document.pages[0].dictionary["Annots"] = PdfArray([PdfReference(32, 0), PdfReference(35, 0)])
        let item = try XCTUnwrap(PdfAttachments.list(document).first)
        XCTAssertTrue(try PdfAttachments.remove(document, item))
        XCTAssertNil(document.get(32))
        XCTAssertNil(document.get(31))
        XCTAssertNil(document.get(30))
        XCTAssertEqual((document.pages[0].dictionary["Annots"] as? PdfArray)?.items.count, 1)
        XCTAssertTrue(PdfAttachments.list(document).isEmpty)
    }

    func test_fileSpecsWithoutStreamsAreLeftOut() throws {
        let document = try StructureFixtures.file("/Names <</EmbeddedFiles <</Names [(a) 33 0 R (b) 99 0 R (c) 31 0 R]>>>>") { pdf in
            pdf.obj(33, "<</Type /Filespec /F (outside.pdf)>>")
            pdf.stream(30, "", "x")
            pdf.obj(31, "<</F (c.txt) /EF <</F 30 0 R>>>>")
        }
        XCTAssertEqual(PdfAttachments.list(document).map { $0.name }, ["c"])
    }

    func test_fileNameFallsBackToTheTreeKey() throws {
        let document = try StructureFixtures.file("/Names <</EmbeddedFiles <</Names [(key) 31 0 R]>>>>") { pdf in
            pdf.stream(30, "", "x")
            pdf.obj(31, "<</EF <</UF 30 0 R>>>>")
        }
        let list = PdfAttachments.list(document)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "key")
        XCTAssertEqual(list[0].fileName, "key")
    }

    func test_worksInAnEncryptedDocument() throws {
        let id = (1...16).map { UInt8($0) }
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .all, strength: .aes256, firstId: id, random: SeededRandom(5))
        let encrypted = try PdfDocument.open(try StructureFixtures.open().saveRewrite(PdfSaveOptions(security: security)))
        XCTAssertTrue(encrypted.isEncrypted)

        let data = Array(String(repeating: "secret ", count: 100).utf8)
        try PdfAttachments.add(encrypted, "secret.txt", data, mimeType: "text/plain", description: "Hidden")
        let reopened = try PdfDocument.open(try encrypted.saveIncremental())
        let list = PdfAttachments.list(reopened)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].description, "Hidden")
        XCTAssertEqual(try PdfAttachments.extract(reopened, list[0]), data)

        let rewritten = try PdfDocument.open(try encrypted.saveRewrite(PdfSaveOptions(security: encrypted.security)))
        XCTAssertEqual(try PdfAttachments.extract(rewritten, PdfAttachments.list(rewritten)[0]), data)
    }

    func test_portfolioFieldsAreRead() throws {
        let document = try StructureFixtures.file("/Collection 30 0 R") { pdf in
            pdf.obj(30, "<</Type /Collection /View /T /D (first.txt) /Schema <</Type /CollectionSchema /Size <</Subtype /N /N (Bytes) /O 3 /V false>> /Name <</Subtype /S /N (Title) /O 1 /E true>> /Odd 5>>>>")
        }
        let portfolio = try XCTUnwrap(PdfPortfolio.read(document))
        XCTAssertEqual(portfolio.view, "T")
        XCTAssertEqual(portfolio.initialDocument, "first.txt")
        XCTAssertEqual(portfolio.fields.map { $0.key }, ["Name", "Size"])
        XCTAssertEqual(portfolio.fields[0].label, "Title")
        XCTAssertEqual(portfolio.fields[0].type, "S")
        XCTAssertTrue(portfolio.fields[0].visible)
        XCTAssertTrue(portfolio.fields[0].editable)
        XCTAssertEqual(portfolio.fields[1].label, "Bytes")
        XCTAssertEqual(portfolio.fields[1].type, "N")
        XCTAssertFalse(portfolio.fields[1].visible)
    }

    func test_noCollectionNoPortfolio() throws {
        XCTAssertNil(PdfPortfolio.read(try StructureFixtures.open()))
        let bare = try StructureFixtures.file("/Collection <<>>")
        XCTAssertEqual(PdfPortfolio.read(bare)?.view, "D")
    }
}
