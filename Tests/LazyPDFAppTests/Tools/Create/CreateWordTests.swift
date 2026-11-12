import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// The Create tool's Word source: the model, the job and its notice. Follows windows/LazyPDF.App.Tests/Tools/convert/WordCreateTests.cs.

private final class RepoFonts: FontSource {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fonts")

    func find(_ family: String, _ style: FontStyles) -> FontFile? {
        let face: String
        switch style {
        case [.bold, .italic]: face = "BoldItalic"
        case .bold: face = "Bold"
        case .italic: face = "Italic"
        default: face = "Regular"
        }
        let name = family.replacingOccurrences(of: " ", with: "") + "-" + face
        let folder = Self.folder.appendingPathComponent(family.split(separator: " ")[0].lowercased())
        return (try? Data(contentsOf: folder.appendingPathComponent(name + ".ttf"))).map { FontFile([UInt8]($0)) }
    }
}

@MainActor
private final class WordStand: ToolFilePicker {
    var files: [ToolFile] = []
    private(set) var asked: [[ToolFileKind]] = []

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] {
        asked.append(kinds)
        return files
    }

    func pickFolder() async -> ToolFile? { nil }
}

@MainActor
final class CreateWordTests: XCTestCase {
    private let a4 = PdfPageSetup()

    private func docx(_ body: String) throws -> [UInt8] {
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        let main = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
        return try ExportZip.make([
            ExportZipEntry("[Content_Types].xml", Array(("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"\(main)\"/></Types>").utf8)),
            ExportZipEntry("_rels/.rels", Array(("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(rel)\" Target=\"word/document.xml\"/></Relationships>").utf8)),
            ExportZipEntry("word/document.xml", Array(("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"
                + body + "</w:body></w:document>").utf8)),
        ])
    }

    private func paragraph(_ text: String) -> String { "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>" }

    private func request(_ url: URL) -> CreateRequest { CreateRequest(.word, a4, "Letter.pdf", files: [url]) }

    func test_theModelNeedsAFileAndHidesThePageSetup() async throws {
        let f = ViewModelFixture(self)
        let stand = WordStand()
        f.vm.filePicker = stand
        let model = CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts())
        model.choose(.word)

        XCTAssertFalse(model.canRun)
        XCTAssertFalse(model.showsSetup)
        XCTAssertNil(model.request())

        stand.files = [ToolFile(url: f.dir.file("report.docx", try docx(paragraph("x"))))]
        await model.chooseWord()

        XCTAssertEqual(stand.asked, [[.word]])
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.request()?.source, .word)
        XCTAssertEqual(model.request()?.title, "report.pdf")
        XCTAssertEqual(model.request()?.files.map(\.lastPathComponent), ["report.docx"])
    }

    func test_aNewChoiceEndsTheGrantOfTheOldOne() async throws {
        let f = ViewModelFixture(self)
        let stand = WordStand()
        f.vm.filePicker = stand
        let model = CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts())
        model.choose(.word)
        let grant = Grant()
        stand.files = [ToolFile(url: f.dir.file("a.docx", [1]), access: grant)]
        await model.chooseWord()
        stand.files = [ToolFile(url: f.dir.file("b.docx", [1]))]
        await model.chooseWord()

        XCTAssertEqual(grant.stops, 1)
        XCTAssertEqual(model.wordFile?.url.lastPathComponent, "b.docx")
    }

    func test_aWordFileBecomesATabWithANoteThatTheLayoutCanDiffer() async throws {
        let f = ViewModelFixture(self)
        let url = f.dir.file("letter.docx", try docx(paragraph("Dear reader")))

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(url))

        let tab = try XCTUnwrap(f.vm.activeDocument)
        XCTAssertEqual(tab.title, "Letter.pdf")
        XCTAssertTrue(tab.isDirty)
        XCTAssertEqual(f.vm.message?.isError, false)
        XCTAssertEqual(f.vm.message?.title, "Made without Office")
        XCTAssertEqual(f.vm.message?.text, "Layout can differ from Word.")
    }

    func test_whatTheConverterLeftOutIsListedSortedByKind() async throws {
        let f = ViewModelFixture(self)
        let body = "<w:p><w:r><w:t>Text</w:t></w:r><w:r><w:footnoteReference w:id=\"2\"/></w:r><w:r><w:commentReference w:id=\"1\"/></w:r></w:p>"
        let url = f.dir.file("notes.docx", try docx(body))

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(url))

        XCTAssertEqual(f.vm.message?.text, "Layout can differ from Word. Left out: comment marks, footnotes.")
    }

    func test_aFileThatIsNotAWordDocumentIsAProblem() async throws {
        let f = ViewModelFixture(self)

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(f.dir.file("a.docx", Array("not a zip at all".utf8))))

        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(f.vm.message?.title, "Word file cannot be read")
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_anOldDocFileIsNotSupported() async throws {
        let f = ViewModelFixture(self)
        let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 600)

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(f.dir.file("old.docx", ole)))

        XCTAssertEqual(f.vm.message?.title, "Word file is not supported")
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_aMissingFileIsAProblemNotACrash() async throws {
        let f = ViewModelFixture(self)

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(f.dir.sub("gone.docx")))

        XCTAssertEqual(f.vm.message?.title, "Word file cannot be read")
    }

    func test_aCancelStopsTheConversionBeforeTheFileIsRead() throws {
        let f = ViewModelFixture(self)
        let url = f.dir.file("letter.docx", try docx(paragraph("x")))
        let token = CancelToken()
        token.cancel()

        XCTAssertThrowsError(try PdfMaker.make(request(url), FakeCodec(), RepoFonts(), token))
    }
}
