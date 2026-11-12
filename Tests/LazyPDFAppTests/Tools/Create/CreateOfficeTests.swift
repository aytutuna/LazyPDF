import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// The Create tool's Word and Excel source: the model, the job and its notice. Follows windows/LazyPDF.App.Tests/Tools/convert/OfficeCreateTests.cs.

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
private final class OfficeStand: ToolFilePicker {
    var files: [ToolFile] = []
    private(set) var asked: [[ToolFileKind]] = []

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] {
        asked.append(kinds)
        return files
    }

    func pickFolder() async -> ToolFile? { nil }
}

@MainActor
final class CreateOfficeTests: XCTestCase {
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

    private func xlsx(_ sheet: String) throws -> [UInt8] {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let sheetType = "application/vnd.openxmlformats-officedocument.spreadsheetml."
        return try ExportZip.make([
            ExportZipEntry("[Content_Types].xml", Array(("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"\(sheetType)sheet.main+xml\"/>"
                + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"\(sheetType)worksheet+xml\"/>"
                + "<Override PartName=\"/xl/worksheets/sheet2.xml\" ContentType=\"\(sheetType)worksheet+xml\"/></Types>").utf8)),
            ExportZipEntry("_rels/.rels", Array(("<Relationships xmlns=\"\(pkg)\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>").utf8)),
            ExportZipEntry("xl/workbook.xml", Array(("<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/>"
                + "<sheet name=\"H\" sheetId=\"2\" state=\"hidden\" r:id=\"rId2\"/></sheets></workbook>").utf8)),
            ExportZipEntry("xl/_rels/workbook.xml.rels", Array(("<Relationships xmlns=\"\(pkg)\"><Relationship Id=\"rId1\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet2.xml\"/></Relationships>").utf8)),
            ExportZipEntry("xl/worksheets/sheet1.xml", Array("<worksheet xmlns=\"\(main)\">\(sheet)</worksheet>".utf8)),
            ExportZipEntry("xl/worksheets/sheet2.xml", Array("<worksheet xmlns=\"\(main)\"><sheetData/></worksheet>".utf8)),
        ])
    }

    private func cell(_ text: String) -> String {
        "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>\(text)</t></is></c></row></sheetData>"
    }

    private func paragraph(_ text: String) -> String { "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>" }

    private func request(_ url: URL) -> CreateRequest { CreateRequest(.office, a4, "Letter.pdf", files: [url]) }

    func test_theModelNeedsAFileAndHidesThePageSetup() async throws {
        let f = ViewModelFixture(self)
        let stand = OfficeStand()
        f.vm.filePicker = stand
        let model = CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts())
        model.choose(.office)

        XCTAssertFalse(model.canRun)
        XCTAssertFalse(model.showsSetup)
        XCTAssertNil(model.request())

        stand.files = [ToolFile(url: f.dir.file("report.docx", try docx(paragraph("x"))))]
        await model.chooseOffice()

        XCTAssertEqual(stand.asked, [[.office]])
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.request()?.source, .office)
        XCTAssertEqual(model.request()?.title, "report.pdf")
        XCTAssertEqual(model.request()?.files.map(\.lastPathComponent), ["report.docx"])
    }

    func test_aNewChoiceEndsTheGrantOfTheOldOne() async throws {
        let f = ViewModelFixture(self)
        let stand = OfficeStand()
        f.vm.filePicker = stand
        let model = CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts())
        model.choose(.office)
        let grant = Grant()
        stand.files = [ToolFile(url: f.dir.file("a.docx", [1]), access: grant)]
        await model.chooseOffice()
        stand.files = [ToolFile(url: f.dir.file("b.docx", [1]))]
        await model.chooseOffice()

        XCTAssertEqual(grant.stops, 1)
        XCTAssertEqual(model.officeFile?.url.lastPathComponent, "b.docx")
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

    func test_anExcelFileBecomesATabWithANoteThatNamesExcel() async throws {
        let f = ViewModelFixture(self)
        let url = f.dir.file("sales.xlsx", try xlsx(cell("Quarterly sales")))

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(url))

        XCTAssertEqual(f.vm.activeDocument?.title, "Letter.pdf")
        XCTAssertEqual(f.vm.message?.isError, false)
        XCTAssertEqual(f.vm.message?.title, "Made without Office")
        XCTAssertEqual(f.vm.message?.text, "Layout can differ from Excel. Left out: hidden sheets.")
    }

    func test_whatAWorkbookHadThatWasLeftOutIsListedSortedByKind() async throws {
        let f = ViewModelFixture(self)
        let sheet = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Total</t></is></c><c r=\"B1\"><f>1+1</f></c></row></sheetData>"
            + "<conditionalFormatting sqref=\"A1\"><cfRule type=\"cellIs\" priority=\"1\"/></conditionalFormatting>"
        let url = f.dir.file("sales.xlsx", try xlsx(sheet))

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(url))

        XCTAssertEqual(f.vm.message?.text,
                       "Layout can differ from Excel. Left out: conditional formatting, formulas without a saved result (shown empty), hidden sheets.")
    }

    func test_aFileThatIsNotAnExcelWorkbookIsAProblem() async throws {
        let f = ViewModelFixture(self)

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(f.dir.file("a.xlsx", Array("not a zip at all".utf8))))

        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(f.vm.message?.title, "Excel file cannot be read")
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_anOldXlsFileIsNotSupported() async throws {
        let f = ViewModelFixture(self)
        let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 600)

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(f.dir.file("old.xlsx", ole)))

        XCTAssertEqual(f.vm.message?.title, "Excel file is not supported")
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_aWorkbookWithNothingToPrintIsNotSupported() async throws {
        let f = ViewModelFixture(self)

        try await CreateJob.run(f.vm, FakeCodec(), RepoFonts(), request(f.dir.file("empty.xlsx", try xlsx("<sheetData/>"))))

        XCTAssertEqual(f.vm.message?.title, "Excel file is not supported")
    }

    func test_officeFilesAreToldApartByTheirExtension() {
        XCTAssertEqual(FileKinds.officeApp(URL(fileURLWithPath: "/a/Letter.DOCX")), .word)
        XCTAssertEqual(FileKinds.officeApp(URL(fileURLWithPath: "/a/sales.xlsx")), .excel)
        XCTAssertNil(FileKinds.officeApp(URL(fileURLWithPath: "/a/old.xls")))
        XCTAssertEqual(FileKinds.officeExtensions, ["docx", "xlsx"])
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
