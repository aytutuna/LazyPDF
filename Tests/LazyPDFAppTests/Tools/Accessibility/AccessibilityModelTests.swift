import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The accessibility panel as the window drives it: the check on show and on a change, the fixes of its rows, tagging, the tag
// tree, the figures' descriptions and the reading aloud with a stand-in voice. Windows has no test of the panel itself; the
// rows, labels and figures have theirs (AccessibilityRowsTests, FigureDescriptionTests, TagTreeAndReadingTests).

@MainActor
private final class FakeSpeaker: Speaker {
    var said: [String] = []
    var holdAt: Int?
    var fails = false
    private var waiting: CheckedContinuation<Void, Error>?

    func say(_ text: String) async throws {
        if fails { throw SpeechUnavailable() }
        said.append(text)
        if said.count == holdAt { try await withCheckedThrowingContinuation { waiting = $0 } }
    }

    func stop() {
        waiting?.resume(throwing: CancellationError())
        waiting = nil
    }
}

@MainActor
final class AccessibilityModelTests: XCTestCase {
    private func pictures(_ count: Int = 1) throws -> [UInt8] {
        try PdfFromPictures.create(Array(repeating: [1], count: count), FakeCodec()).bytes
    }

    private func prose() throws -> [UInt8] {
        let page = (0..<12).map { "Paragraph \($0) has its own words and numbers \(100 + $0)." }.joined(separator: "\n\n")
        return try PdfFromText.create(page, fonts: FakeFonts()).bytes
    }

    private func signedPictures() throws -> [UInt8] {
        let document = try PdfDocument.open(try pictures())
        _ = try AutoTagger.tag(document)
        let perms = PdfDictionary()
        perms["UR3"] = try document.add(PdfDictionary())
        document.catalog["Perms"] = perms
        return try document.saveRewrite(PdfSaveOptions())
    }

    private func attached(_ bytes: [UInt8]? = nil, speaker: FakeSpeaker? = nil) async throws -> (model: AccessibilityModel, rig: ToolRig) {
        let rig = try ToolRig(bytes ?? Pdfs.text(2))
        let voice = speaker ?? FakeSpeaker()
        let model = AccessibilityModel(speaker: { voice })
        rig.attach(model)
        await waitUntil { !model.rows.isEmpty }
        return (model, rig)
    }

    private func tag(_ model: AccessibilityModel, _ rig: ToolRig) async {
        model.setView(.tags)
        await model.action!.run()
        await waitUntil { rig.tab.document.isTagged }
    }

    private func row(_ model: AccessibilityModel, _ rule: AccessibilityRule) throws -> CheckRow {
        try XCTUnwrap(model.rows.first { $0.id == rule })
    }

    func test_aTaggingRequestOpensTheTagsViewWithAddTagsPinned() async throws {
        let rig = try SecurityRig(Pdfs.text(2), password: nil)
        rig.host.openTagging()
        let model = AccessibilityModel(speaker: { FakeSpeaker() })
        rig.attach(model)

        XCTAssertEqual(model.view, .tags)
        XCTAssertEqual(model.action?.text, "Add tags")
        XCTAssertFalse(rig.host.taggingRequested)
    }

    func test_theCheckRunsWhenThePanelIsShownAndSaysHowTheFileDid() async throws {
        let (model, _) = try await attached()

        let passed = model.rows.filter { $0.level == .passed }.count
        let failed = model.rows.filter { $0.level == .failed }.count
        let person = model.rows.count - passed - failed
        XCTAssertEqual(model.checkSummary, "\(passed) passed, \(failed) failed, \(person) need a person.")
        XCTAssertEqual(model.view, .check)
        XCTAssertEqual(model.action?.text, "Check")
        XCTAssertTrue(model.action!.canRun())
    }

    func test_theButtonChecksAgainAndSaysTheCountsInTheStatus() async throws {
        let (model, rig) = try await attached()

        await model.action!.run()

        let status = try XCTUnwrap(rig.host.statuses.last)
        XCTAssertNotNil(status.range(of: #"^\d+ failed, \d+ passed$"#, options: .regularExpression), status)
    }

    func test_aFileThatIsSignedSaysThatChangesBreakTheSignatures() async throws {
        let (model, _) = try await attached(try Pdfs.signed(certified: false))

        XCTAssertTrue(model.isSigned)
    }

    func test_aTypedTitleSurvivesTheCheckThatFollowsAChange() async throws {
        let (model, rig) = try await attached()
        try row(model, .title).value = "My own title"
        let before = model.rows.first

        try Pdfs.retitle(rig.tab.session, "Other")
        try rig.tab.commit("Properties")
        await waitUntil { self.rebuilt(model, since: before) }

        XCTAssertEqual(try row(model, .title).value, "My own title")
        XCTAssertTrue(try row(model, .title).edited)
    }

    private func rebuilt(_ model: AccessibilityModel, since old: CheckRow?) -> Bool {
        guard let first = model.rows.first else { return false }
        return first !== old
    }

    func test_savingTheTitleChangesTheFileAndSaysSo() async throws {
        let (model, rig) = try await attached()
        let title = try row(model, .title)
        title.value = "Lease for the flat"

        model.save(title)

        XCTAssertEqual(DocumentMetadata.read(rig.tab.document).title, "Lease for the flat")
        XCTAssertEqual(rig.tab.session.undoLabel, "Title")
        XCTAssertEqual(rig.host.statuses.last, "Saved.")
    }

    func test_anEmptyTitleIsNotSaved() async throws {
        let (model, rig) = try await attached()
        let title = try row(model, .title)
        title.value = "   "

        model.save(title)

        XCTAssertEqual(rig.host.problems.last?.title, "Title is empty")
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_aLanguageThatIsNotATagIsExplained() async throws {
        let (model, rig) = try await attached()
        let language = try row(model, .language)
        language.value = "not a tag!"

        model.save(language)

        XCTAssertEqual(rig.host.problems.last?.title, "Language is not valid")
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_theLanguageIsSavedAsOneUndoStep() async throws {
        let (model, rig) = try await attached()
        let language = try row(model, .language)
        language.value = "tr-TR"

        model.save(language)

        XCTAssertEqual(rig.tab.session.undoLabel, "Language")
        XCTAssertEqual(AccessibilityEdits.languageOf(rig.tab.document), "tr-TR")
    }

    func test_thePlaceButtonSendsTheViewerToThePage() async throws {
        let item = AccessibilityItem(.figureAlt, "Figures", .failed, "Two figures.", [AccessibilityPlace(1, nil)], .none)
        let (model, rig) = try await attached()

        model.place(CheckRow(item))

        XCTAssertEqual(rig.viewer.sent, [1])
    }

    func test_theTagRowOffersTheTagsViewAndThePinnedButtonThenAddsThem() async throws {
        let (model, _) = try await attached()
        let tagged = try row(model, .tagged)
        XCTAssertEqual(tagged.action, .addTags)

        model.act(tagged)

        XCTAssertEqual(model.view, .tags)
        XCTAssertEqual(model.action?.text, "Add tags")
    }

    func test_addingTagsTagsTheFileAsOneStepAndSaysWhatWasTagged() async throws {
        let (model, rig) = try await attached(try prose())

        await tag(model, rig)

        XCTAssertEqual(rig.tab.session.undoLabel, "Add tags")
        XCTAssertEqual(rig.host.notices.last?.title, "Tags added")
        XCTAssertTrue(rig.host.notices.last?.text.hasPrefix("1 pages tagged:") == true)
        XCTAssertEqual(rig.host.statuses.last, "Tags added.")
        XCTAssertFalse(model.isTagging)
        try rig.tab.undo()
        XCTAssertFalse(rig.tab.document.isTagged)
    }

    func test_addingTagsGivesAFileWithoutALanguageTheOnePreferred() async throws {
        let (model, rig) = try await attached(try prose())
        let wanted = AccessibilityEdits.languageOf(rig.tab.document)
        XCTAssertNil(PdfText.read(rig.tab.document, rig.tab.document.catalog, "Lang"))

        await tag(model, rig)

        XCTAssertEqual(PdfText.read(rig.tab.document, rig.tab.document.catalog, "Lang"), wanted)
    }

    func test_aFileThatHasTagsAlreadyIsToldSoAndNothingChanges() async throws {
        let (model, rig) = try await attached(try prose())
        await tag(model, rig)
        rig.host.notices.removeAll()
        let steps = rig.tab.revision

        await model.addTags()

        XCTAssertEqual(rig.host.notices.last?.title, "Already tagged")
        XCTAssertEqual(rig.tab.revision, steps)
    }

    func test_theTagsViewSaysWhenThereAreNoTags() async throws {
        let (model, _) = try await attached()

        model.setView(.tags)
        await waitUntil { model.tagsNote == "The file has no tags. Add them so a screen reader can read it in order." }

        XCTAssertTrue(model.tagNodes.isEmpty)
    }

    func test_theTagTreeListsTheTagsAndAPickedOneTakesTheViewerToItsPage() async throws {
        let (model, rig) = try await attached(try prose())
        await tag(model, rig)
        await waitUntil { !model.tagNodes.isEmpty }

        XCTAssertTrue(model.tagsNote.hasSuffix("tags. Pick one to go to its page."))
        let paragraph = try XCTUnwrap(model.tagNodes.compactMap { $0.children }.flatMap { $0 }.first { $0.element?.type == "P" } ?? model.tagNodes.first)
        model.selectNode(paragraph)

        XCTAssertEqual(rig.viewer.sent, [0])
    }

    func test_theFiguresOfAPictureFileAreListedAndTheFirstWithoutADescriptionIsShown() async throws {
        let (model, rig) = try await attached(try pictures(2))
        await tag(model, rig)

        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }

        XCTAssertEqual(model.figures.count, 2)
        XCTAssertEqual(model.figuresNote, "2 of 2 figures have no description.")
        XCTAssertEqual(model.altText, "")
        XCTAssertTrue(model.canFindBare)
        XCTAssertFalse(model.canSaveAlt)
        await waitUntil { model.figurePicture != nil }
    }

    func test_aDescriptionIsSavedAndTheNextFigureWithoutOneIsShown() async throws {
        let (model, rig) = try await attached(try pictures(2))
        await tag(model, rig)
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }

        model.typeAlt("A grey square.")
        XCTAssertTrue(model.canSaveAlt)
        model.saveAlt()

        XCTAssertEqual(rig.tab.session.undoLabel, "Figure description")
        XCTAssertEqual(rig.host.statuses.last, "Description saved.")
        await waitUntil { model.selectedFigure == 2 && model.figures.first?.hasAlt == true }
        XCTAssertEqual(model.figuresNote, "1 of 2 figures have no description.")
    }

    func test_aDescriptionOnASignedFileWaitsForTheAnswer() async throws {
        let (model, rig) = try await attached(try signedPictures())
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }
        model.typeAlt("A grey square.")

        model.saveAlt()

        XCTAssertEqual(rig.host.notices.last?.title, "Check before going on")
        XCTAssertFalse(rig.tab.session.canUndo)

        rig.host.notices[0].action?.run()
        XCTAssertEqual(rig.tab.session.undoLabel, "Figure description")
    }

    func test_aDescriptionIsNotWrittenWhenAnotherTabIsShownBeforeTheAnswer() async throws {
        let (model, rig) = try await attached(try signedPictures())
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }
        model.typeAlt("A grey square.")
        model.saveAlt()

        try ToolRig().attach(model)
        rig.host.notices[0].action?.run()

        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_addingTagsToAFileThatForbidsChangesSaysSo() async throws {
        let rig = try ToolRig(try Pdfs.restricted(PdfPermissions.all.subtracting(.modify)), password: "")
        let model = AccessibilityModel(speaker: { FakeSpeaker() })
        rig.attach(model)

        await model.addTags()

        XCTAssertEqual(rig.host.problems.last?.title, "This file cannot be changed")
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_addingTagsToASignedFileWaitsForTheAnswer() async throws {
        let (model, rig) = try await attached(try Pdfs.signed(certified: false))

        await model.addTags()
        XCTAssertEqual(rig.host.notices.last?.title, "Check before going on")
        XCTAssertFalse(rig.tab.session.canUndo)

        rig.host.notices[0].action?.run()
        await waitUntil { rig.tab.document.isTagged }
        await waitUntil { rig.host.notices.last?.title == "Tags added" }
        XCTAssertFalse(model.isTagging)
    }

    func test_whenEveryFigureHasADescriptionThePanelSaysSo() async throws {
        let (model, rig) = try await attached(try pictures(1))
        await tag(model, rig)
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }

        model.typeAlt("A grey square.")
        model.saveAlt()

        await waitUntil { model.figuresNote == "Every figure has a description." }
        XCTAssertEqual(model.altText, "A grey square.")
        XCTAssertFalse(model.canSaveAlt)
    }

    func test_whatWasTypedForAFigureIsKeptWhenAnotherIsPicked() async throws {
        let (model, rig) = try await attached(try pictures(2))
        await tag(model, rig)
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }

        model.typeAlt("Half written")
        model.selectFigure(2)
        XCTAssertEqual(model.altText, "")
        model.selectFigure(1)

        XCTAssertEqual(model.altText, "Half written")
        XCTAssertTrue(model.canSaveAlt)
        XCTAssertEqual(rig.viewer.sent.last, 0)
    }

    private func removeFigure(_ tab: DocumentTab, _ index: Int) throws {
        let tree = try XCTUnwrap(StructureTree.read(tab.document))
        tree.remove(FigureFinder.list(tree)[index].element)
        try tree.write(tab.document)
    }

    func test_aDraftForAnotherFigureSurvivesTheSaveOfThisOne() async throws {
        let (model, rig) = try await attached(try pictures(2))
        await tag(model, rig)
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }
        model.selectFigure(2)
        model.typeAlt("Half written")
        model.selectFigure(1)
        model.typeAlt("A grey square.")

        model.saveAlt()
        await waitUntil { model.figures.first?.hasAlt == true }
        model.selectFigure(2)

        XCTAssertEqual(model.altText, "Half written")
        XCTAssertTrue(model.canSaveAlt)
    }

    func test_removingAFigureDropsItsDraftAndKeepsTheOthersUnderTheirNewNumber() async throws {
        let (model, rig) = try await attached(try pictures(2))
        await tag(model, rig)
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }
        model.typeAlt("For the first")
        model.selectFigure(2)
        model.typeAlt("For the second")

        try removeFigure(rig.tab, 0)
        XCTAssertTrue(try rig.tab.commit("Remove figure"))
        await waitUntil { model.figures.count == 1 }

        model.selectFigure(1)
        XCTAssertEqual(model.altText, "For the second")
        XCTAssertEqual(model.drafts.count, 1)
    }

    func test_aFigureThatVanishedIsNotDescribed() async throws {
        let (model, rig) = try await attached(try pictures(2))
        await tag(model, rig)
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }
        model.selectFigure(2)
        model.typeAlt("Words")
        try removeFigure(rig.tab, 1)
        let before = rig.tab.session.undoLabel

        model.saveAlt()

        XCTAssertEqual(rig.host.problems.last?.text, "The figure is no longer in the file.")
        XCTAssertEqual(rig.tab.session.undoLabel, before)
    }

    func test_nextWithoutOneWrapsRoundToTheFigureThatLacksIt() async throws {
        let (model, rig) = try await attached(try pictures(3))
        await tag(model, rig)
        model.setView(.figures)
        await waitUntil { model.selectedFigure == 1 }
        model.typeAlt("Done")
        model.saveAlt()
        await waitUntil { model.selectedFigure == 2 }

        model.selectFigure(3)
        model.nextBare()

        XCTAssertEqual(model.selectedFigure, 2)
    }

    func test_aFileWithNoTagsHasNoFiguresAndSaysToAddTagsFirst() async throws {
        let (model, _) = try await attached()

        model.setView(.figures)
        await waitUntil { model.figuresNote == "The file has no tags, so no figures are known. Add tags first." }

        XCTAssertTrue(model.figures.isEmpty)
    }

    func test_cancellingAddTagsLeavesTheFileAsItWas() async throws {
        let rig = try ToolRig(Pdfs.text(60))
        let model = AccessibilityModel(speaker: { FakeSpeaker() })
        model.attach(rig.tab, rig.viewer, CancellingHost())
        model.setView(.tags)
        await waitUntil { model.untagged }
        let before = rig.tab.session.current

        await model.action!.run()

        XCTAssertEqual(rig.tab.session.current, before)
        XCTAssertFalse(rig.tab.session.canUndo)
        XCTAssertFalse(model.isTagging)
        XCTAssertFalse(rig.tab.document.isTagged)
    }

    func test_theReadingOrderIsListedAndReadAloudFromTheStart() async throws {
        let voice = FakeSpeaker()
        let (model, rig) = try await attached(try prose(), speaker: voice)
        await tag(model, rig)
        model.setView(.read)
        await waitUntil { model.canRead }
        XCTAssertTrue(model.readNote.hasSuffix("lines, in the order a screen reader reads them."))

        model.toggleReading()
        XCTAssertTrue(model.isReading)
        await waitUntil { !model.isReading }

        XCTAssertEqual(voice.said, model.lines.map(ReadingLines.spoken).filter { !$0.isEmpty })
        XCTAssertNil(model.readIndex)
    }

    func test_readingStartsAtThePickedLine() async throws {
        let voice = FakeSpeaker()
        let (model, rig) = try await attached(try prose(), speaker: voice)
        await tag(model, rig)
        model.setView(.read)
        await waitUntil { model.canRead }

        model.selectLine(3)
        model.toggleReading()
        await waitUntil { !model.isReading }

        XCTAssertEqual(voice.said.first, ReadingLines.spoken(model.lines[3]))
    }

    func test_theButtonStopsTheReading() async throws {
        let voice = FakeSpeaker()
        voice.holdAt = 2
        let (model, rig) = try await attached(try prose(), speaker: voice)
        await tag(model, rig)
        model.setView(.read)
        await waitUntil { model.canRead }

        model.toggleReading()
        await waitUntil { voice.said.count == 2 }
        model.toggleReading()
        await waitUntil { !model.isReading }

        XCTAssertEqual(voice.said.count, 2)
        XCTAssertTrue(rig.host.problems.isEmpty)
    }

    func test_aChangeToTheFileStopsTheReading() async throws {
        let voice = FakeSpeaker()
        voice.holdAt = 1
        let (model, rig) = try await attached(try prose(), speaker: voice)
        await tag(model, rig)
        model.setView(.read)
        await waitUntil { model.canRead }
        model.toggleReading()
        await waitUntil { voice.said.count == 1 }

        try Pdfs.retitle(rig.tab.session, "Other")
        try rig.tab.commit("Properties")

        await waitUntil { !model.isReading }
    }

    func test_theCheckButtonStopsTheReading() async throws {
        let voice = FakeSpeaker()
        voice.holdAt = 1
        let (model, rig) = try await attached(try prose(), speaker: voice)
        await tag(model, rig)
        model.setView(.read)
        await waitUntil { model.canRead }
        model.toggleReading()
        await waitUntil { voice.said.count == 1 }

        await model.action!.run()

        await waitUntil { !model.isReading }
        XCTAssertEqual(model.view, .check)
        XCTAssertEqual(voice.said.count, 1)
    }

    func test_aNewDocumentIsReadFromItsFirstLine() async throws {
        let (model, rig) = try await attached(try prose())
        await tag(model, rig)
        model.setView(.read)
        await waitUntil { model.canRead }
        model.selectLine(3)

        model.detach()
        XCTAssertNil(model.readIndex)

        model.attach(rig.tab, rig.viewer, rig.host)
        model.setView(.read)
        await waitUntil { model.canRead }
        model.selectLine(3)
        try Pdfs.retitle(rig.tab.session, "Other")
        try rig.tab.commit("Properties")

        await waitUntil { model.readIndex == nil }
    }

    func test_aVoiceThatCannotSpeakIsExplained() async throws {
        let voice = FakeSpeaker()
        voice.fails = true
        let (model, rig) = try await attached(try prose(), speaker: voice)
        await tag(model, rig)
        model.setView(.read)
        await waitUntil { model.canRead }

        model.toggleReading()
        await waitUntil { !model.isReading }

        XCTAssertEqual(rig.host.problems.last?.title, "Cannot read aloud")
    }

    func test_aFileWithoutTagsHasNoReadingOrderToRead() async throws {
        let (model, _) = try await attached()

        model.setView(.read)
        await waitUntil { model.readNote == "The file has no tags, so it has no reading order. Add tags first." }

        XCTAssertFalse(model.canRead)
    }

    func test_detachLetsGoOfEverything() async throws {
        let (model, rig) = try await attached(try prose())
        await tag(model, rig)
        await waitUntil { !model.tagNodes.isEmpty }

        model.detach()

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.tagNodes.isEmpty)
        XCTAssertNil(model.tab)
        XCTAssertFalse(model.action!.canRun())
    }
}
