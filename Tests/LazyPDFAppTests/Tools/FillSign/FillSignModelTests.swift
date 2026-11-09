import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The fill and sign panel as the window drives it. Windows has no tests of FillSignPanel or SignatureMaker, so these are written
// for the models: the saved list, the maker, arming the pointer and what a click or a drag places.

@MainActor
final class StubSignatureSystem: SignatureSystem {
    var faces = ["Script", "Print"]
    var typedCalls: [(text: String, face: String)] = []
    var turn = 1

    func typed(_ text: String, face: String) -> PdfRgbaImage? {
        typedCalls.append((text, face))
        return PdfRgbaImage(8, 4, (0..<32).flatMap { _ in [UInt8(0), 0, 0, 255] })
    }

    func orientation(of file: [UInt8]) -> Int { turn }
}

@MainActor
final class FillSignMakerTests: XCTestCase {
    private func maker(_ codec: ImageCodec = PictureCodec(nil)) -> (SignatureMakerModel, StubSignatureSystem) {
        let system = StubSignatureSystem()
        return (SignatureMakerModel(system: system, codec: codec), system)
    }

    private func tempFile(_ name: String = "photo.jpg") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func test_typingANameMakesAnImageInTheFaceChosen() {
        let (maker, system) = maker()
        XCTAssertNil(maker.image)

        maker.setName("Ada Lovelace")
        maker.setFace(1)

        XCTAssertNotNil(maker.image)
        XCTAssertEqual(system.typedCalls.last?.text, "Ada Lovelace")
        XCTAssertEqual(system.typedCalls.last?.face, "Print")
        maker.setName("   ")
        XCTAssertNil(maker.image)
    }

    func test_drawingMakesAnImageWhenAStrokeEndsAndTheLastStrokeCanBeTakenBack() {
        let (maker, _) = maker()
        maker.setMode(.draw)

        maker.beginStroke(ViewPoint(10, 10))
        maker.extendStroke(ViewPoint(80, 30))
        XCTAssertNil(maker.image)
        maker.endStroke()
        XCTAssertNotNil(maker.image)
        maker.beginStroke(ViewPoint(20, 60))
        maker.extendStroke(ViewPoint(90, 70))
        maker.endStroke()
        let two = maker.image
        maker.undoStroke()

        XCTAssertEqual(maker.strokes.strokes.count, 1)
        XCTAssertLessThan(maker.image?.height ?? 0, two?.height ?? 0)
        maker.clearInk()
        XCTAssertNil(maker.image)
    }

    func test_eachModeShowsItsOwnImage() {
        let (maker, _) = maker()
        maker.setName("Ada")
        maker.setMode(.draw)
        XCTAssertNil(maker.image)

        maker.beginStroke(ViewPoint(5, 5))
        maker.extendStroke(ViewPoint(50, 5))
        maker.endStroke()
        maker.setMode(.picture)
        XCTAssertNil(maker.image)
        maker.setMode(.type)

        XCTAssertNotNil(maker.image)
        XCTAssertEqual(maker.name, "Ada")
    }

    func test_aPictureIsChosenFromTheFilePickerAndCanBeTurned() async throws {
        var pixels = [UInt8](repeating: 250, count: 30 * 20 * 4)
        for x in 5..<25 {
            for c in 0..<3 { pixels[(10 * 30 + x) * 4 + c] = 10 }
        }
        let (maker, _) = maker(PictureCodec(PdfRgbaImage(30, 20, pixels)))
        let picker = FormsPicker()
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        picker.picked = [ToolFile(url: url)]
        maker.setMode(.picture)

        await maker.choosePicture(using: picker)

        let made = try XCTUnwrap(maker.image)
        XCTAssertEqual(maker.pictureNote, url.lastPathComponent)
        XCTAssertTrue(maker.canTurn)
        maker.turnPicture()
        XCTAssertEqual([maker.image?.width, maker.image?.height], [made.height, made.width])
    }

    func test_aFileThatIsNotAPictureSaysSoAndLeavesNoImage() async throws {
        let (maker, _) = maker(PictureCodec(nil))
        let picker = FormsPicker()
        let url = try tempFile("notes.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        picker.picked = [ToolFile(url: url)]
        maker.setMode(.picture)

        await maker.choosePicture(using: picker)

        XCTAssertNil(maker.image)
        XCTAssertFalse(maker.canTurn)
        XCTAssertEqual(maker.pictureNote, "That file is not a picture Lazy PDF can read. Choose a PNG or JPEG.")
    }

    func test_nothingPickedLeavesThePictureAsItWas() async {
        let (maker, _) = maker()
        maker.setMode(.picture)

        await maker.choosePicture(using: FormsPicker())

        XCTAssertNil(maker.image)
        XCTAssertEqual(maker.pictureNote, "Sign on white paper and take a photo. The paper is made see-through.")
    }

    func test_startingOverEmptiesEveryMode() {
        let (maker, _) = maker()
        maker.setName("Ada")
        maker.setMode(.draw)
        maker.beginStroke(ViewPoint(1, 1))
        maker.endStroke()

        maker.reset()

        XCTAssertEqual(maker.mode, .type)
        XCTAssertEqual(maker.name, "")
        XCTAssertTrue(maker.strokes.isEmpty)
        XCTAssertNil(maker.image)
    }
}

@MainActor
final class FillSignModelTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fillsign-\(UUID().uuidString)", isDirectory: true)

    private func cleanUp() {
        addTeardownBlock { [folder] in try? FileManager.default.removeItem(at: folder) }
    }

    // The stand-in codec reads every saved file as a 150 by 50 picture, so a click places a box of 150 by 50 and the saved list
    // does not depend on the system's picture codec.
    private let wide = PdfRgbaImage(150, 50, [UInt8](repeating: 0, count: 150 * 50 * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : 0 })

    private func rig(_ bytes: [UInt8]? = nil, saved: Int = 1, password: String? = nil) throws -> (model: FillSignModel, rig: ToolRig, store: SavedSignatures) {
        cleanUp()
        let store = SavedSignatures(directory: folder, codec: PictureCodec(wide))
        for _ in 0..<saved {
            try store.add(.signature, wide)
            Thread.sleep(forTimeInterval: 0.003)
        }
        let model = FillSignModel(store: store, fonts: FakeFonts(), system: StubSignatureSystem(), codec: PictureCodec(wide))
        let rig = try ToolRig(bytes, password: password)
        rig.attach(model)
        return (model, rig, store)
    }

    private func tap(_ rig: ToolRig, _ x: Double, _ y: Double, page: Int = 0) {
        let tool = rig.viewer.pointerTool!
        let point = ViewPoint(x, y)
        tool.press(PagePointer(page: page, point: point, view: point, pressed: true, clicks: 1))
        tool.release(PagePointer(page: page, point: point, view: point, pressed: false, clicks: 0))
    }

    func test_theSavedSignaturesAreListedWithTheNewestSelected() throws {
        let (model, _, _) = try rig(saved: 2)

        XCTAssertEqual(model.saved.count, 2)
        XCTAssertEqual(model.selected, model.saved[0].id)
        XCTAssertEqual(model.saved[0].name, "Saved signature")
        XCTAssertTrue(model.action!.canRun())
    }

    func test_withNothingSavedThereIsNothingToPlace() throws {
        let (model, _, _) = try rig(saved: 0)

        XCTAssertTrue(model.saved.isEmpty)
        XCTAssertFalse(model.action!.canRun())
    }

    func test_aClickPlacesTheSignatureAsOneUndoableStep() async throws {
        let (model, rig, _) = try rig()
        XCTAssertEqual(model.action?.text, "Place on page")

        await model.action!.run()

        XCTAssertTrue(model.placing)
        XCTAssertNotNil(rig.viewer.pointerTool)
        XCTAssertEqual(model.action?.text, "Stop placing")
        XCTAssertTrue(model.hint.hasPrefix("Click the page, or drag a box, to place it."))
        tap(rig, 300, 400)

        let stamps = PdfAnnotations.readAll(rig.tab.document)
        XCTAssertEqual(stamps.count, 1)
        XCTAssertEqual(stamps[0].rect.width, 150, accuracy: 0.001)
        XCTAssertEqual(stamps[0].rect.height, 50, accuracy: 0.001)
        XCTAssertEqual(rig.tab.session.undoLabel, "Place signature")
        XCTAssertFalse(model.placing)
        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertEqual(rig.host.statuses.last, "Placed on page 1.")
    }

    func test_aDragFillsABoxOfThePicturesProportions() async throws {
        let (model, rig, _) = try rig()
        await model.action!.run()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        tool.press(PagePointer(page: 0, point: ViewPoint(100, 100), view: ViewPoint(100, 100), pressed: true, clicks: 1))
        tool.move(PagePointer(page: 0, point: ViewPoint(400, 160), view: ViewPoint(400, 160), pressed: true, clicks: 0))
        XCTAssertNotNil(rig.viewer.overlay(0).item("fillsign.outline"))
        tool.release(PagePointer(page: 0, point: ViewPoint(400, 160), view: ViewPoint(400, 160), pressed: false, clicks: 0))

        let stamp = try XCTUnwrap(PdfAnnotations.readAll(rig.tab.document).first)
        XCTAssertEqual(stamp.rect.width, 180, accuracy: 0.001)
        XCTAssertEqual(stamp.rect.height, 60, accuracy: 0.001)
        XCTAssertNil(rig.viewer.overlay(0).item("fillsign.outline"))
    }

    func test_aDragTooSmallForABoxIsAClickAtTheStartOfIt() async throws {
        let (model, rig, _) = try rig()
        await model.action!.run()
        let tool = try XCTUnwrap(rig.viewer.pointerTool)

        tool.press(PagePointer(page: 0, point: ViewPoint(300, 400), view: ViewPoint(300, 400), pressed: true, clicks: 1))
        tool.release(PagePointer(page: 0, point: ViewPoint(310, 402), view: ViewPoint(310, 402), pressed: false, clicks: 0))

        let stamp = try XCTUnwrap(PdfAnnotations.readAll(rig.tab.document).first)
        XCTAssertEqual(stamp.rect.width, 150, accuracy: 0.001)
    }

    func test_initialsAreSmallerThanASignature() async throws {
        let (model, rig, store) = try rig(saved: 0)
        try store.add(.initials, wide)
        model.selectKind(.initials)
        XCTAssertEqual(model.saved.count, 1)
        XCTAssertEqual(model.saved[0].name, "Saved initials")

        await model.action!.run()
        tap(rig, 300, 400)

        XCTAssertEqual(try XCTUnwrap(PdfAnnotations.readAll(rig.tab.document).first).rect.width, 60, accuracy: 0.001)
    }

    func test_theSecondPressOfTheButtonStopsPlacing() async throws {
        let (model, rig, _) = try rig()
        await model.action!.run()

        await model.action!.run()

        XCTAssertFalse(model.placing)
        XCTAssertNil(rig.viewer.pointerTool)
        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_changingTheKindOrLeavingThePanelStopsPlacing() async throws {
        let (model, rig, _) = try rig()
        await model.action!.run()

        model.selectKind(.text)
        XCTAssertFalse(model.placing)
        XCTAssertNil(rig.viewer.pointerTool)

        model.selectKind(.signature)
        await model.action!.run()
        model.detach()
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_escapeEndsThePlacement() async throws {
        let (model, rig, _) = try rig()
        await model.action!.run()

        rig.viewer.pointerTool?.cancel()

        XCTAssertFalse(model.placing)
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_aLineOfTextIsPlacedWhereTheClickIs() async throws {
        let (model, rig, _) = try rig()
        model.selectKind(.text)
        XCTAssertFalse(model.action!.canRun())
        model.words = "  Approved  "
        XCTAssertTrue(model.action!.canRun())
        model.size = 18

        await model.action!.run()
        XCTAssertTrue(model.hint.hasPrefix("Click the page where the text starts."))
        tap(rig, 72, 200)

        let note = try XCTUnwrap(PdfAnnotations.readAll(rig.tab.document).first)
        XCTAssertEqual(note.type, .freeText)
        XCTAssertEqual(note.contents, "Approved")
        XCTAssertEqual(rig.tab.session.undoLabel, "Place text")
    }

    func test_todaysDateGoesInTheFormatChosen() async throws {
        let (model, rig, _) = try rig()
        model.selectKind(.date)
        model.formatIndex = 2
        XCTAssertTrue(model.action!.canRun())
        XCTAssertEqual(model.dates.count, 4)

        await model.action!.run()
        tap(rig, 72, 200)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(PdfAnnotations.readAll(rig.tab.document).first?.contents, formatter.string(from: Date()))
        XCTAssertEqual(model.dates[2].sample, formatter.string(from: Date()))
    }

    func test_textTheFontsCannotDrawIsRefusedAndChangesNothing() async throws {
        let (model, rig, _) = try rig()
        model.selectKind(.text)
        model.words = "\u{00C7}a\u{011F}r\u{0131}"

        await model.action!.run()
        tap(rig, 72, 200)

        XCTAssertEqual(rig.host.problems.map(\.title), ["Text cannot be drawn"])
        XCTAssertFalse(rig.tab.isDirty)
        XCTAssertFalse(model.placing)
    }

    func test_aSignedFileAsksBeforeTheFirstPlacementOnly() async throws {
        let (model, rig, _) = try rig(try Pdfs.signed(certified: false))

        await model.action!.run()

        XCTAssertFalse(model.placing)
        XCTAssertEqual(rig.host.notices.map(\.title), ["Check before going on"])
        rig.host.notices[0].action?.run()
        XCTAssertTrue(model.placing)
        tap(rig, 300, 400)
        await model.action!.run()
        XCTAssertTrue(model.placing)
        XCTAssertEqual(rig.host.notices.count, 1)
    }

    func test_aFileThatForbidsCommentsCannotBePlacedOn() async throws {
        let (model, rig, _) = try rig(try Pdfs.restricted(.print), password: "")

        await model.action!.run()

        XCTAssertFalse(model.placing)
        XCTAssertEqual(rig.host.problems.map(\.title), ["This file cannot be changed"])
    }

    func test_aNewSignatureIsKeptAndSelectedWhenTheSwitchIsOn() throws {
        let (model, _, store) = try rig(saved: 0)
        model.makeNew()
        XCTAssertTrue(model.showMaker)
        model.maker.setName("Ada")

        model.useMade()

        XCTAssertFalse(model.showMaker)
        XCTAssertEqual(store.list(.signature).count, 1)
        XCTAssertEqual(model.saved.count, 1)
        XCTAssertEqual(model.selected, model.saved[0].id)
        XCTAssertTrue(model.action!.canRun())
    }

    func test_aNewSignatureNotKeptIsStillUsedOnce() throws {
        let (model, _, store) = try rig(saved: 1)
        model.makeNew()
        model.maker.setName("Ada")
        model.maker.keep = false

        model.useMade()

        XCTAssertEqual(store.list(.signature).count, 1)
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.action!.canRun())
    }

    func test_cancellingTheSheetKeepsTheListAsItWas() throws {
        let (model, _, _) = try rig()
        let before = model.selected
        model.makeNew()

        model.cancelMaker()

        XCTAssertFalse(model.showMaker)
        XCTAssertEqual(model.selected, before)
    }

    func test_aRemovedSignatureLeavesTheList() throws {
        let (model, _, _) = try rig(saved: 2)

        model.remove(model.saved[0])

        XCTAssertEqual(model.saved.count, 1)
        XCTAssertEqual(model.selected, model.saved[0].id)
    }

    func test_aSignatureThatCannotBeKeptIsStillUsedAndSaysSo() throws {
        cleanUp()
        let blocker = folder.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: blocker)
        let store = SavedSignatures(directory: blocker.appendingPathComponent("inside"), codec: PictureCodec(wide))
        let model = FillSignModel(store: store, fonts: FakeFonts(), system: StubSignatureSystem(), codec: PictureCodec(wide))
        let rig = try ToolRig()
        rig.attach(model)
        model.makeNew()
        model.maker.setName("Ada")

        model.useMade()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Signature not kept"])
        XCTAssertTrue(model.action!.canRun())
    }
}
