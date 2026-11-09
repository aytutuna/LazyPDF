import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/convert/ExportToolTests.cs: which pages, what each format writes and what the window
// is told. Left out: PagesAreDrawnFromACopyThatLaterEditsDoNotReach checks PageCount of a WIC renderer, which the
// DocumentRenderer protocol has no member for, so the copy is checked by what it draws. OnlyTheChosenPagesAreWritten reads
// the text format instead of the docx, since the zip reader of the engine's tests is not in this test target.
// AFolderThatIsNotThereIsAProblemNotACrash has no path to give: the files are written in a folder of the app's own and the
// person picks where they go afterwards, so it is tested as a write into a missing folder and as the person giving up.

@MainActor
private final class StubExporter: ToolFileExporter {
    var answer: [URL]?
    private(set) var offered: [[URL]] = []
    private(set) var contents: [String: Int] = [:]

    func export(_ files: [URL]) async -> [URL] {
        offered.append(files)
        for file in files { contents[file.lastPathComponent] = (try? Data(contentsOf: file))?.count ?? -1 }
        return answer ?? files.map { URL(fileURLWithPath: "/Users/me/Documents").appendingPathComponent($0.lastPathComponent) }
    }
}

final class ExportToolTests: XCTestCase {
    private func source(_ name: String, _ pdf: [UInt8], codec: ImageCodec? = FakeCodec(), password: String? = nil,
                        renderer: PageRenderer = FakeRenderer()) -> ExportSource {
        ExportSource(pdf: pdf, password: password, certificate: nil, renderer: renderer, codec: codec, stem: name)
    }

    // Text on the first line of a page reads as a running head, so the pages start lower down.
    private func report(_ pages: Int) -> [UInt8] {
        Pdfs.text(pages, "\n\n\n\nHello from the tests.\nA second line to follow it.\nIt ends")
    }

    private func png() throws -> [UInt8] {
        try PngWriter.encode(PdfRgbaImage(8, 8, [UInt8](repeating: 200, count: 8 * 8 * 4)))
    }

    private func write(_ source: ExportSource, _ options: ExportOptions, _ dir: TempDir, token: CancelToken = CancelToken()) throws -> ExportResult {
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        return try Exporter.write(source, options, to: dir.url, token)
    }

    private func names(_ dir: TempDir) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted()
    }

    func test_pagesAreAllTheCurrentOneOrWhatWasTyped() {
        XCTAssertNil(ExportPages.of(.all, "", current: 2, count: 5).pages)
        XCTAssertEqual(ExportPages.of(.current, "", current: 2, count: 5).pages, [2])
        XCTAssertEqual(ExportPages.of(.typed, "1-2, 5, 2", current: 0, count: 5).pages, [0, 1, 4])
    }

    func test_pagesTypedWrongSayWhatIsWrong() {
        XCTAssertNotNil(ExportPages.of(.typed, "9", current: 0, count: 5).error)
        XCTAssertNotNil(ExportPages.of(.typed, "", current: 0, count: 5).error)
        XCTAssertNotNil(ExportPages.of(.typed, "two", current: 0, count: 5).error)
    }

    func test_everyFormatWritesAFile() throws {
        let formats: [(ExportFormat, String)] = [(.word, ".docx"), (.excel, ".xlsx"), (.powerPoint, ".pptx"), (.html, ".html"),
                                                 (.markdown, ".md"), (.rtf, ".rtf"), (.text, ".txt")]
        for (format, fileExtension) in formats {
            let dir = TempDir(self)
            let options = ExportOptions(format)
            XCTAssertEqual(options.fileExtension, fileExtension)

            let result = try write(source("out", report(2)), options, dir)

            let target = dir.sub("out" + fileExtension)
            XCTAssertEqual(result, ExportResult(files: [target]), "\(format)")
            XCTAssertGreaterThan(try Data(contentsOf: target).count, 20, "\(format)")
            XCTAssertEqual(try names(dir), ["out" + fileExtension], "\(format)")
        }
    }

    func test_onlyTheChosenPagesAreWritten() throws {
        let dir = TempDir(self)

        _ = try write(source("out", report(3)), ExportOptions(.text, pages: [1]), dir)

        let body = try String(contentsOf: dir.sub("out.txt"), encoding: .utf8)
        XCTAssertTrue(body.contains("Page 2"))
        XCTAssertFalse(body.contains("Page 1"))
        XCTAssertFalse(body.contains("Page 3"))
    }

    #if canImport(CoreText)
    func test_turkishTextSurvivesAsUtf8() throws {
        let dir = TempDir(self)
        let pdf = try PdfFromText.create("Çalışma notları: ğ ş ı İ ö ü", fonts: CoreTextFontSource()).bytes

        _ = try write(source("out", pdf), ExportOptions(.text), dir)

        let bytes = try Data(contentsOf: dir.sub("out.txt"))
        XCTAssertNotEqual(bytes.first, 0xEF)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Çalışma notları: ğ ş ı İ ö ü"))
    }
    #endif

    func test_htmlCanKeepTheLinesWhereTheyAre() throws {
        let reflowed = TempDir(self), fixed = TempDir(self)

        _ = try write(source("a", report(1)), ExportOptions(.html), reflowed)
        _ = try write(source("a", report(1)), ExportOptions(.html, fixedHtml: true), fixed)

        let one = try String(contentsOf: reflowed.sub("a.html"), encoding: .utf8)
        let two = try String(contentsOf: fixed.sub("a.html"), encoding: .utf8)
        XCTAssertNotEqual(one, two)
        XCTAssertTrue(two.replacingOccurrences(of: " ", with: "").contains("position:absolute"))
    }

    func test_picturesOfPagesAreNumberedAndNeverReplaceFiles() throws {
        let dir = TempDir(self)
        let pictures = source("Report", report(12))
        let options = ExportOptions(.pictures, pages: [0, 11], dpi: 72)

        let first = try write(pictures, options, dir)
        _ = try write(pictures, options, dir)

        XCTAssertEqual(first.files.count, 2)
        XCTAssertEqual(try names(dir), ["Report page 01 (2).png", "Report page 01.png", "Report page 12 (2).png", "Report page 12.png"])
        XCTAssertEqual(Array(try Data(contentsOf: dir.sub("Report page 01.png")).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    #if canImport(ImageIO)
    func test_jpegPicturesAreJpeg() throws {
        let dir = TempDir(self)

        _ = try write(source("a", report(1), codec: ImageIOCodec()), ExportOptions(.pictures, picture: .jpeg, quality: 60), dir)

        XCTAssertEqual(Array(try Data(contentsOf: dir.sub("a page 1.jpg")).prefix(2)), [0xFF, 0xD8])
    }
    #endif

    func test_pagesTheSystemCannotDrawAreCounted() throws {
        let dir = TempDir(self)
        let renderer = FakeRenderer()
        renderer.draws = false

        let result = try write(source("a", report(2), renderer: renderer), ExportOptions(.pictures), dir)

        XCTAssertEqual(result.files.count, 0)
        XCTAssertEqual(result.skipped, 2)
    }

    func test_picturesInTheFileAreSavedAsTheyAre() throws {
        let dir = TempDir(self)
        let codec = FakeCodec()
        let pdf = try PdfFromPictures.create([try png()], codec).bytes

        let result = try write(source("a", pdf, codec: codec), ExportOptions(.images), dir)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(try names(dir).filter { $0.hasPrefix("page1_") && $0.hasSuffix(".png") }.count, 1)
    }

    func test_aFileOpenedWithAPasswordIsReadWithIt() throws {
        let dir = TempDir(self)
        let document = try PdfDocument.open(report(1))
        let security = PdfSecurity.create(userPassword: "open", ownerPassword: "owner", permissions: .all, strength: .aes256,
                                          firstId: document.firstId ?? [])
        let locked = try document.saveRewrite(PdfSaveOptions(security: security))

        _ = try write(source("out", locked, password: "open"), ExportOptions(.text), dir)

        XCTAssertTrue(try String(contentsOf: dir.sub("out.txt"), encoding: .utf8).contains("Hello from the tests"))
    }

    func test_aCopyBanStopsTheExportForWhoOpenedWithoutTheOwnerPassword() throws {
        XCTAssertFalse(Exporter.allowed(try PdfDocument.open(Pdfs.restricted(.print))))
        XCTAssertTrue(Exporter.allowed(try PdfDocument.open(Pdfs.restricted([.print, .copy]))))
        XCTAssertTrue(Exporter.allowed(try PdfDocument.open(Pdfs.restricted(.none), password: "owner")))
        XCTAssertTrue(Exporter.allowed(try PdfDocument.open(report(1))))
    }

    func test_aCancelledExportWritesNoFile() throws {
        let dir = TempDir(self)
        let token = CancelToken()
        token.cancel()

        XCTAssertThrowsError(try write(source("out", report(3)), ExportOptions(.word), dir, token: token)) { XCTAssertTrue($0 is CancellationError) }

        XCTAssertEqual(try names(dir), [])
    }

    func test_aWriteIntoAFolderThatIsNotThereFailsWithAFileError() throws {
        let dir = TempDir(self)
        let missing = dir.sub("missing")

        XCTAssertThrowsError(try Exporter.write(source("out", report(1)), ExportOptions(.text), to: missing, CancelToken())) {
            XCTAssertTrue(Problems.isFileSystem($0))
            XCTAssertEqual(ExportProblems.failed($0, "a.pdf").title, "Not exported")
        }
    }

    func test_aFileThatIsTooBigForTheFormatIsReportedAsSuch() {
        let problem = ExportProblems.failed(PdfReadException(.unsupported, "too large"), "a.pdf")

        XCTAssertEqual(problem.title, "Too large to export")
    }

    private func page(_ index: Int, _ blocks: ExportBlock...) -> ExportPage {
        ExportPage(index, 612, 792, blocks, [], [])
    }

    private func table() -> ExportTable { ExportTable(DisplayRect(0, 0, 100, 50), [["a", "b"]], nil, false) }

    private func words() -> ExportParagraph { ExportParagraph(DisplayRect(0, 60, 100, 12), [ExportRun("words", false, false, 11)]) }

    func test_aScanWithNoTextWritesNothingAndSaysSo() throws {
        let dir = TempDir(self)
        let blank = try PdfFromText.create(String(repeating: "\u{0C}", count: 2), fonts: FakeFonts()).bytes

        let result = try write(source("out", blank), ExportOptions(.text), dir)

        XCTAssertEqual(result, ExportResult(files: [], gap: .noText))
        XCTAssertEqual(try names(dir), [])
    }

    func test_aWorkbookWithTablesLeavesOutTheTextAroundThem() {
        let tablesOnly = ExportDocument(nil, [page(0, table()), page(1, table())], 11)
        let mixed = ExportDocument(nil, [page(0, table(), words())], 11)

        XCTAssertEqual(Exporter.excelGap(tablesOnly), .none)
        XCTAssertEqual(Exporter.excelGap(mixed), .outsideTables)
    }

    func test_aWorkbookStopsAtAThousandSheets() {
        let pages = (0..<1001).map { page($0, words()) }
        let tables = (0..<1001).map { page($0, table()) }

        XCTAssertEqual(Exporter.excelGap(ExportDocument(nil, pages, 11)), .pastSheetLimit)
        XCTAssertEqual(Exporter.excelGap(ExportDocument(nil, tables, 11)), .pastSheetLimit)
        XCTAssertEqual(Exporter.excelGap(ExportDocument(nil, Array(pages.prefix(1000)), 11)), .none)
    }

    func test_picturesOfAllPagesAreSavedPageByPage() throws {
        let dir = TempDir(self)
        let codec = FakeCodec()
        let pdf = try PdfFromPictures.create([try png(), try png(), try png()], codec).bytes

        let result = try write(source("a", pdf, codec: codec), ExportOptions(.images, pages: [2, 0]), dir)

        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(try names(dir).map { String($0.prefix(6)) }, ["page1_", "page3_"])
    }

    func test_aFailedWriteLeavesNoTempFileAndAFileOfThatNameAloneWhenItWorks() throws {
        let dir = TempDir(self)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try "mine".write(to: dir.sub("out.txt.tmp"), atomically: true, encoding: .utf8)

        _ = try Exporter.write(source("out", report(1)), ExportOptions(.text), to: dir.url, CancelToken())
        XCTAssertThrowsError(try Exporter.write(source("out", report(1)), ExportOptions(.text), to: dir.sub("missing"), CancelToken()))

        XCTAssertEqual(try String(contentsOf: dir.sub("out.txt.tmp"), encoding: .utf8), "mine")
        XCTAssertEqual(try names(dir), ["out.txt", "out.txt.tmp"])
    }

    @MainActor
    func test_aFolderIsNamedByItsLastPartOrByTheDriveForARoot() {
        XCTAssertEqual(ExportModel.leaf(URL(fileURLWithPath: "/Users/me/pictures")), "pictures")
        XCTAssertEqual(ExportModel.leaf(URL(fileURLWithPath: "/Users/me/pictures/", isDirectory: true)), "pictures")
        XCTAssertEqual(ExportModel.leaf(URL(fileURLWithPath: "/")), "/")
    }

    func test_pagesAreDrawnFromACopyThatLaterEditsDoNotReach() throws {
        let renderer = FakeRenderer()

        let snapshot = Exporter.snapshot(source("a", report(3))) { renderer }

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(renderer.loads, 1)
        XCTAssertNotNil(snapshot?.render(2, 72))
        renderer.draws = false
        XCTAssertNil(Exporter.snapshot(source("a", report(3))) { renderer })
    }
}

@MainActor
final class ExportModelTests: XCTestCase {
    private func attached(_ f: ViewModelFixture, _ pdf: [UInt8], _ exporter: StubExporter = StubExporter(),
                          renderers: @escaping () -> DocumentRenderer = { FakeRenderer() }) async throws -> (model: ExportModel, tab: DocumentTab, exporter: StubExporter) {
        await f.vm.open(f.dir.file("a.pdf", pdf))
        let tab = try XCTUnwrap(f.vm.activeDocument)
        f.vm.fileExporter = exporter
        let model = ExportModel(codec: FakeCodec(), renderers: renderers)
        model.attach(tab, PanelViewer(tab), f.vm)
        return (model, tab, exporter)
    }

    private func report(_ pages: Int) -> [UInt8] {
        Pdfs.text(pages, "\n\n\n\nHello from the tests.\nA second line to follow it.\nIt ends")
    }

    func test_anExportTellsWhereTheFileWent() async throws {
        let f = ViewModelFixture(self)
        let (model, _, exporter) = try await attached(f, report(2))
        model.format = .markdown

        await model.action!.run()

        XCTAssertEqual(exporter.offered.count, 1)
        XCTAssertEqual(exporter.offered[0].map(\.lastPathComponent), ["a.md"])
        XCTAssertEqual(f.vm.message?.isError, false)
        XCTAssertEqual(f.vm.message?.title, "Exported")
        XCTAssertEqual(f.vm.message?.text, "Saved as a.md.")
        XCTAssertFalse(f.vm.isBusy)
        XCTAssertEqual(f.vm.statusFull, "Export saved.")
    }

    func test_theNoticeOffersToShowTheFileWhereThePlatformCan() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.dir.file("a.pdf", report(1)))
        let tab = try XCTUnwrap(f.vm.activeDocument)
        f.vm.fileExporter = StubExporter()
        var shown: [URL] = []
        let model = ExportModel(codec: FakeCodec(), renderers: { FakeRenderer() }, reveal: { shown.append($0) })
        model.attach(tab, PanelViewer(tab), f.vm)

        await model.action!.run()

        let action = try XCTUnwrap(f.vm.message?.action)
        XCTAssertEqual(action.text, "Show in folder")
        action.run()
        XCTAssertEqual(shown.map(\.lastPathComponent), ["a.docx"])
    }

    func test_theTempFilesAreGoneOnceTheExporterHasThem() async throws {
        let f = ViewModelFixture(self)
        let (model, _, exporter) = try await attached(f, report(1))

        await model.action!.run()

        XCTAssertGreaterThan(exporter.contents["a.docx"] ?? 0, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(exporter.offered.first?.first).path))
    }

    func test_whenThePersonGivesUpNothingIsSaidAndNothingChanges() async throws {
        let f = ViewModelFixture(self)
        let exporter = StubExporter()
        exporter.answer = []
        let (model, tab, _) = try await attached(f, report(2), exporter)
        let revision = tab.revision

        await model.action!.run()

        XCTAssertNil(f.vm.message)
        XCTAssertEqual(tab.revision, revision)
        XCTAssertFalse(f.vm.canUndo)
    }

    func test_aFileWithNoPicturesSaysSo() async throws {
        let f = ViewModelFixture(self)
        let (model, _, exporter) = try await attached(f, Pdfs.text())
        model.format = .images

        await model.action!.run()

        XCTAssertEqual(f.vm.message?.isError, false)
        XCTAssertEqual(f.vm.message?.title, "No pictures found")
        XCTAssertTrue(exporter.offered.isEmpty)
    }

    func test_anExportWithNoTextIsANoticeThatPointsToMakeSearchable() async throws {
        let f = ViewModelFixture(self)
        let blank = try PdfFromText.create(String(repeating: "\u{0C}", count: 2), fonts: FakeFonts()).bytes
        let (model, _, exporter) = try await attached(f, blank)
        model.format = .excel

        await model.action!.run()

        XCTAssertEqual(f.vm.message?.isError, false)
        XCTAssertEqual(f.vm.message?.title, "No text found")
        XCTAssertTrue(f.vm.message?.text.contains("Make searchable") == true)
        XCTAssertTrue(exporter.offered.isEmpty)
    }

    func test_pagesTheSystemCannotDrawAreAProblemNotAnEmptyFolder() async throws {
        let f = ViewModelFixture(self)
        f.draws = false
        let blind = FakeRenderer()
        blind.draws = false
        let (model, _, exporter) = try await attached(f, report(2), renderers: { blind })
        model.format = .pictures

        XCTAssertEqual(model.blocker, "The system cannot draw this file.")
        XCTAssertFalse(model.action!.canRun())
        await model.action!.run()

        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(f.vm.message?.title, "Nothing exported")
        XCTAssertTrue(exporter.offered.isEmpty)
    }

    func test_aFileThatForbidsCopyingBlocksTheButtonAndSaysWhy() async throws {
        let f = ViewModelFixture(self)
        let (model, _, _) = try await attached(f, try Pdfs.restricted(.print))

        XCTAssertEqual(model.blocker, "This file does not allow copying its content.")
        XCTAssertFalse(model.action!.canRun())
    }

    func test_pagesTypedWrongBlockTheButtonAndTheTypedOnesDoNot() async throws {
        let f = ViewModelFixture(self)
        let (model, _, _) = try await attached(f, report(3))
        model.scope = .typed

        model.pagesText = "9"
        XCTAssertNotNil(model.blocker)
        XCTAssertFalse(model.action!.canRun())

        model.pagesText = "2-3"
        XCTAssertNil(model.blocker)
        XCTAssertEqual(model.options.pages, [1, 2])
        XCTAssertTrue(model.action!.canRun())
    }

    func test_thePageShownIsTheOneThisPageMeans() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.dir.file("a.pdf", report(3)))
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let viewer = PanelViewer(tab)
        viewer.pageIndex = 2
        let model = ExportModel(codec: FakeCodec(), renderers: { FakeRenderer() })
        model.attach(tab, viewer, f.vm)
        model.scope = .current

        XCTAssertEqual(model.options.pages, [2])
    }

    func test_exportingDoesNotChangeTheDocument() async throws {
        let f = ViewModelFixture(self)
        let (model, tab, _) = try await attached(f, report(1))
        model.format = .rtf
        let revision = tab.revision

        await model.action!.run()

        XCTAssertEqual(tab.revision, revision)
        XCTAssertFalse(f.vm.canUndo)
    }
}
