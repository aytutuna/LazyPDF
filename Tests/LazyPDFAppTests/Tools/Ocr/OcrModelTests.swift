import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Make searchable panel as the window drives it: pages and language on attach, the choice of pages, the run, the removal,
// and the correction of a word through a field on the page. Windows has no test of the panel itself; the work is tested with
// OcrWorkTests and OcrPagesTests.

@MainActor
final class OcrModelTests: XCTestCase {
    private let english = OcrLanguage(tag: "en-US", name: "English")
    private let turkish = OcrLanguage(tag: "tr-TR", name: "Turkish")

    private func makeModel(_ recognizer: FakeRecognizer = FakeRecognizer(), installed: [OcrLanguage]? = nil) -> OcrModel {
        let state = OcrLanguageState(installed: installed ?? [english, turkish], missing: [])
        return OcrModel(recognizer: recognizer, languages: { state })
    }

    private func attached(_ bytes: [UInt8]? = nil, recognizer: FakeRecognizer = FakeRecognizer()) async throws -> (model: OcrModel, rig: ToolRig) {
        let rig = try ToolRig(bytes ?? Pdfs.text(2))
        let model = makeModel(recognizer)
        rig.attach(model)
        await waitUntil { !model.isLoading }
        return (model, rig)
    }

    // The test pages already have text, so the first run asks; the answer goes on and the layer is waited for.
    private func read(_ model: OcrModel, _ rig: ToolRig, _ pages: [Int]) async {
        await read(model, rig.host, rig.tab, pages)
    }

    private func read(_ model: OcrModel, _ host: RecordingHost, _ tab: DocumentTab, _ pages: [Int]) async {
        for page in pages { model.setSelected(page, true) }
        host.notices.removeAll()
        await model.action!.run()
        host.notices.last?.action?.run()
        await waitUntil { pages.allSatisfy { PdfOcrLayer.has(tab.document, tab.document.pages[$0]) } && !model.isLoading }
    }

    func test_theLanguageStartsOnTheAppsOwnAndTheListHasTheOthers() async throws {
        let (model, _) = try await attached()

        XCTAssertEqual(model.languages.map(\.tag), ["en-US", "tr-TR"])
        XCTAssertFalse(model.language.isEmpty)
    }

    func test_withNoLanguageThereIsNothingToRun() async throws {
        let rig = try ToolRig()
        let model = makeModel(installed: [])
        rig.attach(model)
        await waitUntil { !model.isLoading }
        model.setSelected(0, true)

        XCTAssertEqual(model.language, "")
        XCTAssertFalse(model.action!.canRun())
    }

    func test_thePagesAreListedAndOnlyThoseThatNeedItAreChosen() async throws {
        let (model, _) = try await attached()

        XCTAssertEqual(model.rows.map(\.page), [0, 1])
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertEqual(model.pagesSummary, "No pages need text recognition.")
        XCTAssertFalse(model.action!.canRun())
    }

    func test_whileThePagesAreCheckedThePanelHasNothingToRun() async throws {
        let rig = try ToolRig()
        let model = makeModel()

        rig.attach(model)

        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.pagesSummary, "")
        XCTAssertFalse(model.action!.canRun())
    }

    func test_choosingPagesTurnsOnTheButtonAndARunMakesThemSearchable() async throws {
        let (model, rig) = try await attached()
        model.setSelected(1, true)
        XCTAssertTrue(model.action!.canRun())

        await read(model, rig, [1])

        XCTAssertEqual(rig.host.statuses.last, "Made 1 page searchable")
        XCTAssertEqual(rig.tab.document.pages.map { PdfOcrLayer.has(rig.tab.document, $0) }, [false, true])
        await waitUntil { model.rows.contains { $0.kind == .ownLayer } }
        XCTAssertFalse(model.isRunning)
    }

    func test_pagesThatAlreadyHaveTextAreWarnedAboutBeforeTheyAreReadAgain() async throws {
        let (model, rig) = try await attached()
        model.setSelected(0, true)

        await model.action!.run()

        XCTAssertEqual(rig.host.notices.last?.title, "Check before going on")
        XCTAssertTrue(rig.host.notices.last?.text.contains("1 chosen page already has text.") == true)
        XCTAssertFalse(PdfOcrLayer.has(rig.tab.document, rig.tab.document.pages[0]))

        rig.host.notices.last?.action?.run()
        await waitUntil { PdfOcrLayer.has(rig.tab.document, rig.tab.document.pages[0]) }
    }

    func test_replacingMovesOnlyThePagesTheModeDecidesAbout() async throws {
        let (model, rig) = try await attached(Pdfs.text(3))
        await read(model, rig, [0, 1])
        await waitUntil { model.rows.filter { $0.kind == .ownLayer }.count == 2 }
        model.setSelected(2, true)

        model.setReplacing(true)
        XCTAssertEqual(model.selected, [0, 1, 2])
        model.setReplacing(false)
        XCTAssertEqual(model.selected, [2])
    }

    func test_removingNeedsAChosenPageWithOurLayer() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        XCTAssertFalse(model.canRemove)
        XCTAssertEqual(model.removeNote, "No page has a text layer from here.")
        await read(model, rig, [0])
        await waitUntil { model.rows.first?.kind == .ownLayer }
        XCTAssertEqual(model.removeNote, "Choose pages marked Searchable above.")
        model.setSelected(0, true)
        XCTAssertTrue(model.canRemove)

        model.removeLayers()

        XCTAssertFalse(PdfOcrLayer.has(rig.tab.document, rig.tab.document.pages[0]))
        XCTAssertEqual(rig.host.statuses.last, "Removed from 1 page")
    }

    func test_theWordsOfThePageInViewAreMarkedAndListed() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 }

        XCTAssertEqual(model.words.map(\.text), ["alpha", "beta"])
        let marks = rig.viewer.overlay(0).items.filter { $0.id.hasPrefix("ocr.w.0.") }
        XCTAssertEqual(marks.count, 2)
    }

    func test_turningTheWordsOffTakesTheMarksAndTheListAway() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 }

        model.setShowWords(false)

        XCTAssertTrue(model.words.isEmpty)
        XCTAssertTrue(rig.viewer.overlay(0).items.isEmpty)
        XCTAssertNil(model.picked)
    }

    func test_aPickedWordIsTypedOverInAFieldAndTheCorrectionGoesIn() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 }

        model.pick(WordRef(0, 1), edit: true)

        XCTAssertEqual(model.picked, WordRef(0, 1))
        XCTAssertEqual(model.pickedText, "beta")
        let field = try XCTUnwrap(rig.viewer.overlay(0).field("ocr.word"))
        XCTAssertEqual(field.text, "beta")
        XCTAssertEqual(field.label, "Corrected word")
        field.commit("  gamma ")
        XCTAssertEqual(try PdfOcrLayer.words(rig.tab.document, rig.tab.document.pages[0]).map(\.text), ["alpha", "gamma"])
        XCTAssertEqual(rig.tab.session.undoLabel, "Correct word")
        await waitUntil { model.words.map(\.text) == ["alpha", "gamma"] }
        XCTAssertEqual(model.picked, WordRef(0, 1))
    }

    func test_anEmptyCorrectionRemovesTheWordAndLetsGoOfIt() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 }
        model.pick(WordRef(0, 0), edit: true)

        rig.viewer.overlay(0).field("ocr.word")?.commit("")

        await waitUntil { model.words.map(\.text) == ["beta"] }
        XCTAssertNil(model.picked)
    }

    func test_aCorrectionDoesNotCheckThePagesAgain() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 && !model.isLoading }
        model.pick(WordRef(0, 0), edit: true)

        rig.viewer.overlay(0).field("ocr.word")?.commit("gamma")
        await waitUntil { model.words.first?.text == "gamma" }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(model.isLoading)
    }

    func test_handInPutsTheTypedWordInTheFileAsOneStep() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 }
        model.pick(WordRef(0, 0), edit: true)
        rig.viewer.overlay(0).field("ocr.word")?.typed("gamma")

        XCTAssertTrue(model.handIn())

        XCTAssertEqual(try PdfOcrLayer.words(rig.tab.document, rig.tab.document.pages[0]).map(\.text), ["gamma", "beta"])
        XCTAssertNil(rig.viewer.overlay(0).field("ocr.word"))
        XCTAssertTrue(model.handIn())
    }

    func test_detachLetsGoOfTheTabAndTheViewer() async throws {
        let (model, rig) = try await attached()
        XCTAssertNotNil(rig.viewer.pointerTool)

        model.detach()

        XCTAssertNil(model.tab)
        XCTAssertNil(model.viewer)
        XCTAssertFalse(model.action!.canRun())
    }

    // The stand-in renderer lays the page out at 200 by 300 points, so the points tried lie inside that.
    private func pointerRig(_ bytes: [UInt8]? = nil) async throws -> (model: OcrModel, viewer: ViewerModel, host: RecordingHost, tab: DocumentTab) {
        let host = RecordingHost()
        let session = try PdfEditSession.open(bytes ?? Pdfs.text(1))
        let tab = DocumentTab(session: session, renderer: FakeRenderer(), url: nil, title: "a.pdf")
        let viewer = ViewerModel(makeRenderer: { FakeRenderer() }, openAddress: { _ in })
        viewer.setScreen(viewport: ViewSize(800, 600), pixelsPerDip: 1)
        viewer.show(tab)
        let model = makeModel()
        model.attach(tab, viewer, host)
        await waitUntil { !model.isLoading }
        await read(model, host, tab, [0])
        await waitUntil { model.words.count == 2 }
        return (model, viewer, host, tab)
    }

    // Inside the first word, as the finger test below checks against its box.
    private func onFirstWord(_ viewer: ViewerModel) throws -> ViewPoint {
        try XCTUnwrap(viewer.pageToView(0)).transform(ViewPoint(100, 60))
    }

    func test_aFingerOnAWordPicksItWhenTheyAskForItAndOneAwayFromWordsScrolls() async throws {
        let (model, viewer, _, _) = try await pointerRig()
        model.touchCorrects = true

        let box = model.words[0].box
        XCTAssertTrue(box.x <= 100 && box.x + box.width >= 100 && box.y <= 60 && box.y + box.height >= 60)
        let matrix = try XCTUnwrap(viewer.pageToView(0))
        let onWord = matrix.transform(ViewPoint(100, 60))
        let far = matrix.transform(ViewPoint(100, 295))
        let tool = try XCTUnwrap(viewer.pointerTool)
        XCTAssertTrue(tool === model)

        XCTAssertFalse(viewer.toolTakes(far))
        XCTAssertTrue(viewer.toolTakes(onWord))
        viewer.pointerDown(onWord, touch: true)
        viewer.pointerUp(onWord)

        XCTAssertEqual(model.picked, WordRef(0, 0))
        XCTAssertNotNil(viewer.overlay(0).field("ocr.word"))
    }

    func test_aFingerScrollsWhateverIsUnderItUntilTheyAskToCorrectByTouch() async throws {
        let (model, viewer, _, _) = try await pointerRig()
        let onWord = try onFirstWord(viewer)

        XCTAssertFalse(viewer.toolTakes(onWord))
        model.touchCorrects = true
        XCTAssertTrue(viewer.toolTakes(onWord))
    }

    func test_aFingerThatDraggedAwayFromAWordOpensNoField() async throws {
        let (model, viewer, _, _) = try await pointerRig()
        model.touchCorrects = true
        let start = try onFirstWord(viewer)

        viewer.pointerDown(start, touch: true)
        viewer.pointerMove(ViewPoint(start.x + 3, start.y + 40))
        viewer.pointerUp(ViewPoint(start.x + 3, start.y + 40))

        XCTAssertNil(model.picked)
        XCTAssertNil(viewer.overlay(0).field("ocr.word"))
    }

    func test_aMousePressTheToolDoesNotTakeStaysWithTheViewer() async throws {
        let (model, viewer, _, _) = try await pointerRig()
        let matrix = try XCTUnwrap(viewer.pageToView(0))
        let beside = PagePointer(page: 0, point: ViewPoint(100, 295), view: ViewPoint(0, 0), pressed: true, clicks: 1)
        let inside = PagePointer(page: 0, point: ViewPoint(100, 60), view: ViewPoint(0, 0), pressed: true, clicks: 1)
        XCTAssertFalse(model.takes(beside))
        XCTAssertTrue(model.takes(inside))

        let away = matrix.transform(beside.point)
        viewer.pointerDown(away)
        viewer.pointerUp(away)
        XCTAssertNil(model.picked)

        let on = matrix.transform(inside.point)
        viewer.pointerDown(on)
        viewer.pointerUp(on)
        XCTAssertEqual(model.picked, WordRef(0, 0))
    }

    func test_pickingAnotherWordKeepsWhatWasTypedInTheFirst() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 }
        model.pick(WordRef(0, 0), edit: true)
        rig.viewer.overlay(0).field("ocr.word")?.typed("gamma")

        model.pick(WordRef(0, 1), edit: true)

        XCTAssertEqual(try PdfOcrLayer.words(rig.tab.document, rig.tab.document.pages[0]).map(\.text), ["gamma", "beta"])
        XCTAssertEqual(rig.viewer.overlay(0).field("ocr.word")?.text, "beta")
        XCTAssertTrue(model.handIn())
        XCTAssertNil(rig.viewer.overlay(0).field("ocr.word"))
    }

    func test_aListRowPicksTheWordForTheBoxOfThePanelAndNotAFieldOnThePage() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 }

        model.pickFromList(model.words[1])

        XCTAssertEqual(model.picked, WordRef(0, 1))
        XCTAssertTrue(model.inPanel)
        XCTAssertEqual(model.draft, "beta")
        XCTAssertNil(rig.viewer.overlay(0).field("ocr.word"))
        model.draft = " gamma "
        model.applyDraft()
        XCTAssertEqual(try PdfOcrLayer.words(rig.tab.document, rig.tab.document.pages[0]).map(\.text), ["alpha", "gamma"])
        XCTAssertEqual(rig.tab.session.undoLabel, "Correct word")
        await waitUntil { model.words.map(\.text) == ["alpha", "gamma"] }
        XCTAssertEqual(model.draft, "gamma")
    }

    func test_whatIsTypedInTheBoxOfThePanelGoesInBeforeTheFileIsSaved() async throws {
        let (model, rig) = try await attached(Pdfs.text(1))
        await read(model, rig, [0])
        await waitUntil { model.words.count == 2 }
        model.pickFromList(model.words[0])
        model.draft = "gamma"

        XCTAssertTrue(model.handIn())

        XCTAssertEqual(try PdfOcrLayer.words(rig.tab.document, rig.tab.document.pages[0]).map(\.text), ["gamma", "beta"])
    }

    func test_aWordRemovedByAnEmptyFieldRenumbersTheWordsBeforeTheNextPress() async throws {
        let (model, viewer, _, _) = try await pointerRig()
        model.pick(WordRef(0, 0), edit: true)

        viewer.overlay(0).field("ocr.word")?.commit("")

        // Not waited for: a press in the same gesture reads the words as they are now.
        XCTAssertEqual(model.words.map(\.text), ["beta"])
        XCTAssertEqual(model.words.map(\.index), [0])
        XCTAssertNil(model.picked)
    }

    func test_aWordLeftAsItWasRaisesNoWarningOnASignedFile() async throws {
        let (model, viewer, host, tab) = try await pointerRig(Pdfs.signed(certified: false, pages: 1))
        XCTAssertTrue(tab.document.isSigned)
        model.pick(WordRef(0, 0), edit: true)
        host.notices.removeAll()

        XCTAssertTrue(model.handIn())

        XCTAssertTrue(host.notices.isEmpty)
        XCTAssertNil(viewer.overlay(0).field("ocr.word"))
    }
}
