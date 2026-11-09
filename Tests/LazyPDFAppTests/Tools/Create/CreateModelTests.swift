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
    func pictureFile() -> [UInt8]? { picture }
    func text() -> String? { board }
}

private final class Grant: FileAccess {
    var stopped = false
    func stop() { stopped = true }
}

@MainActor
final class CreateModelTests: XCTestCase {
    private func made(_ f: ViewModelFixture, _ stand: Stand = Stand()) -> CreateModel {
        f.vm.filePicker = stand
        f.vm.clipboard = stand
        return CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts())
    }

    func test_blankPagesNeedANumberFromOneToFiveHundred() {
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

        XCTAssertFalse(grant.stopped)
        model.selection = model.pictures[0].id
        model.removeSelected()

        XCTAssertTrue(model.pictures.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertTrue(grant.stopped)
    }

    func test_textNeedsSomethingBesidesSpaces() {
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

    func test_thePasteboardMakesTextOrAPictureAndTheButtonFollowsIt() {
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

    func test_thePaperOfThePictureIsOnlyOfferedForPicturesAndFallsBackToA4() {
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

    func test_blankPagesKeepTheNormalMarginWhateverWasPicked() throws {
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
}
