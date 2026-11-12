import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Create panel as the sheet and the tool strip drive it: the sources, what lets the button run, the picture list, the text
// file, the pasteboard and the request each source makes. Windows has no test of the panel itself; the maker is tested with
// CreateToolTests.

@MainActor
private final class Stand: ToolFilePicker, ToolClipboard {
    var files: [ToolFile] = []
    var board: String?
    var picture: [UInt8]?
    private(set) var asked: [[ToolFileKind]] = []

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] {
        asked.append(kinds)
        return files
    }

    func pickFolder() async -> ToolFile? { nil }
    private(set) var reads = 0
    var peeksOnly = false

    func pictureFile() -> [UInt8]? {
        reads += 1
        return picture
    }

    func text() -> String? {
        reads += 1
        return board
    }

    func kind() -> ClipboardKind {
        if !peeksOnly { return ClipboardContent.read(self).kind }
        return picture != nil ? .picture : .nothing
    }
}

@MainActor
final class CreateModelTests: XCTestCase {
    private func made(_ f: ViewModelFixture, _ given: Stand? = nil) -> CreateModel {
        let stand = given ?? Stand()
        f.vm.filePicker = stand
        f.vm.clipboard = stand
        return CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts())
    }

    func test_blankPagesNeedANumberFromOneToFiveHundred() async {
        let model = CreateModel(host: nil, codec: FakeCodec(), fonts: FakeFonts())

        XCTAssertTrue(model.canRun)
        XCTAssertNil(model.blocker)
        for bad in ["0", "501", "x", ""] {
            model.blankPages = bad
            XCTAssertFalse(model.canRun, bad)
            XCTAssertEqual(model.blocker, "Type a number from 1 to 500.", bad)
        }
        model.blankPages = "500"
        XCTAssertTrue(model.canRun)
    }

    func test_picturesNeedAtLeastOneAndTheTitleIsTheFileNameWhenThereIsOne() async throws {
        let f = ViewModelFixture(self)
        let stand = Stand()
        let model = made(f, stand)
        model.choose(.pictures)
        XCTAssertFalse(model.canRun)

        stand.files = [ToolFile(url: f.dir.file("holiday.png", [1]))]
        await model.addPictures()

        XCTAssertTrue(model.canRun)
        XCTAssertEqual(stand.asked, [[.picture]])
        XCTAssertEqual(model.request()?.title, "holiday.pdf")
        stand.files = [ToolFile(url: f.dir.file("b.png", [1]))]
        await model.addPictures()
        XCTAssertEqual(model.request()?.title, "Pictures.pdf")
        XCTAssertEqual(model.request()?.files.map(\.lastPathComponent), ["holiday.png", "b.png"])
    }

    func test_thePictureListMovesAndRemovesWhatIsSelected() async throws {
        let f = ViewModelFixture(self)
        let stand = Stand()
        let model = made(f, stand)
        model.choose(.pictures)
        stand.files = ["a", "b", "c"].map { ToolFile(url: f.dir.file($0 + ".png", [1])) }
        await model.addPictures()

        model.selection = model.pictures[0].id
        XCTAssertFalse(model.canMoveUp)
        XCTAssertTrue(model.canMoveDown)
        model.move(1)
        XCTAssertEqual(model.pictures.map(\.name), ["b.png", "a.png", "c.png"])
        model.move(1)
        XCTAssertEqual(model.pictures.map(\.name), ["b.png", "c.png", "a.png"])
        XCTAssertFalse(model.canMoveDown)
        model.move(1)
        XCTAssertEqual(model.pictures.map(\.name), ["b.png", "c.png", "a.png"])

        model.removeSelected()
        XCTAssertEqual(model.pictures.map(\.name), ["b.png", "c.png"])
        XCTAssertEqual(model.selection, model.pictures[1].id)
    }

    func test_aPictureLeavingTheListEndsItsGrant() async throws {
        let f = ViewModelFixture(self)
        let stand = Stand()
        let model = made(f, stand)
        model.choose(.pictures)
        let grant = Grant()
        stand.files = [ToolFile(url: f.dir.file("a.png", [1]), access: grant)]
        await model.addPictures()

        XCTAssertEqual(grant.stops, 0)
        model.selection = model.pictures[0].id
        model.removeSelected()

        XCTAssertTrue(model.pictures.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertEqual(grant.stops, 1)
    }

    func test_textNeedsSomethingBesidesSpaces() async {
        let model = CreateModel(host: nil, codec: FakeCodec(), fonts: FakeFonts())
        model.choose(.text)

        model.typedText = "  \n "
        XCTAssertFalse(model.canRun)
        model.typedText = "Hello"
        XCTAssertTrue(model.canRun)
        XCTAssertEqual(model.request()?.title, "Text.pdf")
        XCTAssertEqual(model.request()?.fontSize, 11)
    }

    func test_aTextFileFillsTheBox() async throws {
        let f = ViewModelFixture(self)
        let stand = Stand()
        let model = made(f, stand)
        model.choose(.text)
        stand.files = [ToolFile(url: f.dir.file("a.txt", Array("Çalışma".utf8)))]

        await model.openTextFile()

        XCTAssertEqual(model.typedText, "Çalışma")
        XCTAssertNil(model.fileProblem)
        XCTAssertEqual(stand.asked, [[.text]])
    }

    func test_aTextFileOverAMegabyteIsRefusedAndTheBoxKeepsItsText() async throws {
        let f = ViewModelFixture(self)
        let stand = Stand()
        let model = made(f, stand)
        model.choose(.text)
        model.typedText = "mine"
        stand.files = [ToolFile(url: f.dir.file("big.txt", [UInt8](repeating: 65, count: TextFiles.mostBytes + 1)))]

        await model.openTextFile()

        XCTAssertEqual(model.typedText, "mine")
        XCTAssertEqual(model.blocker, "That file is too big. Pick a text file under 1 MB.")
        model.inputChanged()
        XCTAssertNil(model.blocker)
    }

    func test_aTextFileThatCannotBeReadIsSaidSoAndGivingUpChangesNothing() async throws {
        let f = ViewModelFixture(self)
        let stand = Stand()
        let model = made(f, stand)
        model.choose(.text)
        model.typedText = "mine"

        await model.openTextFile()
        XCTAssertEqual(model.typedText, "mine")
        XCTAssertNil(model.fileProblem)

        stand.files = [ToolFile(url: f.dir.sub("missing.txt"))]
        await model.openTextFile()
        XCTAssertEqual(model.blocker, "That file could not be read. Check that no other program has it open.")
    }

    func test_thePasteboardMakesTextOrAPictureAndTheButtonFollowsIt() async {
        let f = ViewModelFixture(self)
        let stand = Stand()
        let model = made(f, stand)

        model.choose(.clipboard)
        XCTAssertEqual(model.clipboardState, "Copy text or a picture, then come back.")
        XCTAssertFalse(model.canRun)
        XCTAssertFalse(model.showsSetup)

        stand.picture = [1, 2, 3]
        model.peekClipboard()
        XCTAssertEqual(model.clipboardState, "The clipboard holds a picture.")
        XCTAssertTrue(model.canRun)
        XCTAssertTrue(model.makesPictures)
        XCTAssertEqual(model.request()?.source, .pictures)
        XCTAssertEqual(model.request()?.picture ?? [], [1, 2, 3])
        XCTAssertEqual(model.request()?.title, "Clipboard.pdf")

        stand.board = "words"
        model.peekClipboard()
        XCTAssertEqual(model.clipboardState, "The clipboard holds text.")
        XCTAssertTrue(model.makesText)
        XCTAssertEqual(model.request()?.source, .text)
        XCTAssertEqual(model.request()?.text, "words")
    }

    func test_lookingAtThePasteboardDoesNotReadIt() async {
        let f = ViewModelFixture(self)
        let stand = Stand()
        stand.peeksOnly = true
        stand.picture = [1, 2, 3]
        let model = made(f, stand)

        model.choose(.clipboard)
        model.peekClipboard()

        XCTAssertEqual(model.clipboardState, "The clipboard holds a picture.")
        XCTAssertEqual(stand.reads, 0)
        XCTAssertEqual(model.request()?.picture ?? [], [1, 2, 3])
        XCTAssertGreaterThan(stand.reads, 0)
    }

    func test_aPasteboardThatEmptiedGivesNoRequestAndAnEmptyRunSaysSo() async throws {
        let f = ViewModelFixture(self)
        let stand = Stand()
        stand.board = "words"
        let model = made(f, stand)
        model.choose(.clipboard)
        XCTAssertTrue(model.canRun)

        stand.board = nil
        XCTAssertNil(model.request())
        XCTAssertFalse(model.canRun)
        stand.board = "words"
        model.peekClipboard()
        stand.board = nil
        await model.run()

        XCTAssertEqual(f.vm.message?.title, "Clipboard is empty")
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_thePaperOfThePictureIsOnlyOfferedForPicturesAndFallsBackToA4() async {
        let f = ViewModelFixture(self)
        let stand = Stand()
        let model = made(f, stand)
        model.choose(.pictures)
        model.paper = .picture
        XCTAssertFalse(model.orientationEnabled)

        model.choose(.text)

        XCTAssertEqual(model.paper, .a4)
        XCTAssertTrue(model.orientationEnabled)
        XCTAssertTrue(model.showsMargin)
        XCTAssertTrue(model.makesText)
    }

    private func sized(_ settings: URL? = nil, metric: Bool = true) -> CreateModel {
        CreateModel(host: nil, codec: FakeCodec(), fonts: FakeFonts(), settings: settings, metric: metric, locale: Locale(identifier: "en_US"))
    }

    private func settingsFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-create-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_textAndPicturesTakeTheMorePapersAndPassThemToTheEngine() {
        let model = sized()
        model.choose(.text)
        model.typedText = "Hello"
        let papers: [(CreatePaper, PdfPaper)] = [(.a3, .a3), (.a5, .a5), (.legal, .legal), (.letter, .letter), (.custom, .custom)]

        for (paper, engine) in papers {
            model.paper = paper
            XCTAssertEqual(model.request()?.setup.paper, engine)
        }
    }

    func test_theCustomSizeIsTypedInMillimetersOrInchesAndReachesTheEngineInPoints() {
        let metric = sized()
        metric.choose(.text)
        metric.paper = .custom
        XCTAssertEqual(metric.unit, "mm")
        XCTAssertEqual([metric.customWidth, metric.customHeight], ["210", "297"])
        metric.customWidth = "100"
        metric.customHeight = "200"

        let setup = metric.request()!.setup

        XCTAssertEqual(setup.customWidth, 100 * 72 / 25.4, accuracy: 0.001)
        XCTAssertEqual(setup.customHeight, 200 * 72 / 25.4, accuracy: 0.001)

        let inches = sized(metric: false)
        inches.choose(.text)
        inches.paper = .custom
        XCTAssertEqual(inches.unit, "in")
        XCTAssertEqual([inches.customWidth, inches.customHeight], ["8.5", "11"])
        inches.customWidth = "4"
        inches.customHeight = "6"
        XCTAssertEqual(inches.request()!.setup.customWidth, 288, accuracy: 0.001)
        XCTAssertEqual(inches.request()!.setup.customHeight, 432, accuracy: 0.001)
    }

    func test_theCustomSizeIsHeldToWhatTheEngineAccepts() {
        let model = sized(metric: false)
        model.choose(.text)
        model.typedText = "Hello"
        model.paper = .custom
        XCTAssertTrue(model.showsCustomSize)

        model.customWidth = "200"
        model.customHeight = "0.05"
        XCTAssertTrue(model.canRun)
        XCTAssertNil(model.blocker)
        for bad in ["200.1", "0.04", "x", ""] {
            model.customHeight = bad
            XCTAssertFalse(model.canRun, bad)
            XCTAssertEqual(model.blocker, "Type a size from 0.05 to 200 in.", bad)
        }
        model.paper = .a4
        XCTAssertTrue(model.canRun)
        XCTAssertFalse(model.showsCustomSize)
    }

    func test_thePaperAndCustomSizeAreRememberedInTheSettingsFolder() {
        let folder = settingsFolder()
        let first = sized(folder)
        first.choose(.text)
        first.typedText = "Hello"
        first.paper = .custom
        first.customWidth = "123.5"
        first.customHeight = "200"
        _ = first.request()

        let second = sized(folder)

        XCTAssertEqual(second.paper, .custom)
        XCTAssertEqual([second.customWidth, second.customHeight], ["123.5", "200"])
        XCTAssertEqual(sized(settingsFolder()).paper, .a4)
    }

    func test_thePaperOfThePictureIsKeptForWhenPicturesComeBack() {
        let model = sized()
        model.choose(.pictures)
        model.paper = .picture

        model.choose(.text)
        XCTAssertEqual(model.paper, .a4)
        model.choose(.pictures)

        XCTAssertEqual(model.paper, .picture)
    }

    func test_blankPagesKeepTheNormalMarginWhateverWasPicked() async throws {
        let model = CreateModel(host: nil, codec: FakeCodec(), fonts: FakeFonts())
        model.margin = 72
        model.paper = .letter
        model.orientation = .landscape

        let blank = try XCTUnwrap(model.request())
        XCTAssertEqual(blank.setup.margin, 36)
        XCTAssertEqual(blank.setup.paper, .letter)
        XCTAssertEqual(blank.setup.orientation, .landscape)
        model.choose(.text)
        XCTAssertEqual(model.request()?.setup.margin, 72)
    }

    func test_aRunOpensTheDocumentInANewTab() async throws {
        let f = ViewModelFixture(self)
        let model = made(f)
        model.blankPages = "3"

        await model.run()

        XCTAssertEqual(f.vm.activeDocument?.title, "Blank.pdf")
        XCTAssertEqual(f.vm.activeDocument?.pageCount, 3)
    }

    func test_theStripPanelRunsTheSameModelOnceAttached() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let panel = CreatePanelModel(codec: FakeCodec(), fonts: FakeFonts())
        panel.attach(tab, PanelViewer(tab), f.vm)
        XCTAssertTrue(panel.action!.canRun())

        await panel.action!.run()

        XCTAssertEqual(f.vm.documents.count, 2)
        XCTAssertEqual(f.vm.activeDocument?.title, "Blank.pdf")
        panel.detach()
        XCTAssertNil(panel.create.host)
    }

    func test_droppedPicturesSwitchToPicturesAndOtherFilesAreSaidToBeLeftOut() async {
        let f = ViewModelFixture(self)
        let model = made(f)

        model.drop([ToolFile(url: f.dir.file("a.txt", [1]))])
        XCTAssertEqual(model.from, .blank)
        XCTAssertEqual(f.vm.statusFull, "Only picture files can be added.")

        model.drop([ToolFile(url: f.dir.file("a.JPG", [1])), ToolFile(url: f.dir.file("b.txt", [1])), ToolFile(url: f.dir.file("c.heic", [1]))])
        XCTAssertEqual(model.from, .pictures)
        XCTAssertEqual(model.pictures.map(\.name), ["a.JPG", "c.heic"])
    }
}
