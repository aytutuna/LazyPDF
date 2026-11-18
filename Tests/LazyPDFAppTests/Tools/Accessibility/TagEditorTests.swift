import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/standards/TagEditsTests.cs and TagTreePanelTests.cs: the edits of the tag tree
// editor on a document (one undo step each, what the placement rule refuses, the read-only cases) and the panel model's lines,
// fields, commands, filter and marks.

@MainActor
final class TagEditorTests: XCTestCase {
    private func page(_ number: Int) -> String {
        (0..<6).map { "Paragraph \($0) of page \(number) has its own words and numbers \(number * 100 + $0)." }.joined(separator: "\n\n")
    }

    // Tagged by the tagger: a Document with a paragraph or heading per block and real content behind each.
    private func auto() throws -> [UInt8] {
        let text = try PdfFromText.create(page(1) + "\u{0C}" + page(2), fonts: FakeFonts()).bytes
        let document = try PdfDocument.open(text)
        _ = try AutoTagger.tag(document)
        return try document.saveIncremental()
    }

    // A tree made by hand over a page with no marked content: Document, then what the test adds.
    private func built(_ build: (StructureTree, StructElement) throws -> Void) throws -> [UInt8] {
        let document = try PdfDocument.open(Pdfs.text())
        let tree = StructureTree.create(document)
        let root = StructElement("Document")
        try tree.add(nil, root)
        try build(tree, root)
        try tree.write(document)
        return try document.saveRewrite(PdfSaveOptions())
    }

    private func three() throws -> [UInt8] {
        try built { tree, root in
            let sect = try el(tree, root, "Sect", "sect")
            for title in ["one", "two", "three"] { try el(tree, sect, "P", title) }
        }
    }

    private func restricted() throws -> [UInt8] {
        let document = try PdfDocument.open(try auto())
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: PdfPermissions.all.subtracting(.modify),
                                          strength: .aes256, firstId: [UInt8](repeating: 7, count: 16))
        return try document.saveRewrite(PdfSaveOptions(security: security))
    }

    @discardableResult
    private func el(_ tree: StructureTree, _ parent: StructElement?, _ type: String, _ title: String? = nil) throws -> StructElement {
        let element = StructElement(type)
        element.title = title
        try tree.add(parent, element)
        return element
    }

    private func titled(_ tree: StructureTree, _ title: String) throws -> StructElement {
        try XCTUnwrap(tree.elements.first { $0.title == title }, title)
    }

    private func titles(_ parent: StructElement) -> [String?] {
        parent.children.map(\.title)
    }

    private func read(_ tab: DocumentTab) throws -> StructureTree {
        try XCTUnwrap(StructureTree.read(tab.document))
    }

    private func tab(_ bytes: [UInt8]) throws -> DocumentTab {
        try ToolRig(bytes).tab
    }

    private func command(_ tab: DocumentTab, _ title: String, _ command: TagCommand) throws -> TagOutcome {
        let tree = try read(tab)
        return TagEdits.apply(tab, TagPath.of(tree, try titled(tree, title)), TagEdits.label(command)) { t, k in try TagEdits.run(t, k!, command) }
    }

    private func wholePage(_ tab: DocumentTab) -> TextRange {
        TextRange(0, TextPage.create(tab.document, tab.document.pages[0]).chars.count)
    }

    // MARK: Edits on a document

    func test_aMoveIsOneUndoStepWithItsLabelAndUndoPutsTheOrderBack() async throws {
        let tab = try tab(try three())

        let outcome = try command(tab, "one", .moveDown)

        XCTAssertEqual(outcome.result, .done)
        XCTAssertEqual(tab.session.undoLabel, "Move tag down")
        XCTAssertEqual(titles(try titled(try read(tab), "sect")), ["two", "one", "three"])
        XCTAssertTrue(try tab.undo())
        XCTAssertEqual(titles(try titled(try read(tab), "sect")), ["one", "two", "three"])
    }

    func test_movingUpAndOutdentingAndIndentingChangeTheNesting() async throws {
        let tab = try tab(try three())

        XCTAssertEqual(try command(tab, "three", .moveUp).result, .done)
        XCTAssertEqual(titles(try titled(try read(tab), "sect")), ["one", "three", "two"])

        XCTAssertEqual(try command(tab, "two", .outdent).result, .done)
        XCTAssertEqual(titles(try read(tab).roots[0]), ["sect", "two"])

        XCTAssertEqual(try command(tab, "two", .indent).result, .done)
        XCTAssertEqual(titles(try titled(try read(tab), "sect")), ["one", "three", "two"])
    }

    func test_aMoveThatBreaksTheNestingIsRefusedBeforeAnythingIsWritten() async throws {
        let tab = try tab(try three())
        let tree = try read(tab)

        let reason = TagEdits.refusal(tree, try titled(tree, "two"), .indent)
        let outcome = try command(tab, "two", .indent)

        XCTAssertEqual(reason, AccessibilityText.placementReason(TagRules.textKids))
        XCTAssertEqual(outcome.result, .refused)
        XCTAssertEqual(outcome.reason, reason)
        XCTAssertNil(tab.session.undoLabel)
        XCTAssertFalse(tab.isDirty)
    }

    func test_commandsThatMeanNothingWhereTheNodeStandsAreOff() async throws {
        let tab = try tab(try three())
        let tree = try read(tab)

        XCTAssertFalse(TagEdits.applies(tree, try titled(tree, "one"), .moveUp))
        XCTAssertFalse(TagEdits.applies(tree, try titled(tree, "three"), .moveDown))
        XCTAssertFalse(TagEdits.applies(tree, try titled(tree, "one"), .indent))
        XCTAssertFalse(TagEdits.applies(tree, tree.roots[0], .outdent))
        XCTAssertFalse(TagEdits.applies(tree, try titled(tree, "one"), .makeHeaderRow))
        XCTAssertFalse(TagEdits.applies(tree, try titled(tree, "one"), .markAsArtifact))
        XCTAssertTrue(TagEdits.applies(tree, try titled(tree, "two"), .indent))
    }

    func test_deleteKeepsWhatTheTagHeldAndNeedsItsKidsToFitTheParent() async throws {
        let tab = try tab(try built { tree, root in
            let sect = try el(tree, root, "Sect", "sect")
            try el(tree, sect, "P", "one")
            try el(tree, sect, "P", "two")
            let table = try el(tree, root, "Table", "table")
            let row = try el(tree, table, "TR", "row")
            try el(tree, row, "TD", "cell")
        })

        XCTAssertEqual(try command(tab, "sect", .delete).result, .done)
        XCTAssertEqual(titles(try read(tab).roots[0]), ["one", "two", "table"])
        XCTAssertEqual(tab.session.undoLabel, "Delete tag")

        let refused = try command(tab, "row", .delete)
        XCTAssertEqual(refused.result, .refused)
        XCTAssertEqual(refused.reason, AccessibilityText.placementReason(TagRules.needsRow))
    }

    func test_makeHeaderRowTurnsTheCellsIntoColumnHeaders() async throws {
        let tab = try tab(try built { tree, root in
            let row = try el(tree, try el(tree, root, "Table"), "TR", "row")
            try el(tree, row, "TD", "a")
            try el(tree, row, "TD", "b")
        })

        XCTAssertEqual(try command(tab, "row", .makeHeaderRow).result, .done)

        let tree = try read(tab)
        let cells = try titled(tree, "row").children
        XCTAssertEqual(cells.map(\.type), ["TH", "TH"])
        XCTAssertEqual(cells.map { tree.tableAttributes($0).scope }, [.column, .column])
        XCTAssertEqual(tab.session.undoLabel, "Make header row")
    }

    func test_theFieldsChangeTypeTextAndTableAttributes() async throws {
        let tab = try tab(try built { tree, root in
            let row = try el(tree, try el(tree, root, "Table"), "TR")
            try el(tree, row, "TD", "cell")
            try el(tree, root, "P", "para")
        })
        let tree = try read(tab)
        let table = TagEdits.tableOf(scope: "Row", rowSpan: "2", colSpan: "3", headers: "a1, b2")
        XCTAssertNil(table.problem)

        let cell = TagEdits.apply(tab, TagPath.of(tree, try titled(tree, "cell")), "Change tag") { t, k in
            TagEdits.setProperties(t, k as! StructElement, TagProperties(type: "TH", title: "Head", alt: "Alt words", actualText: "Spoken", lang: "tr-TR", table: table.attributes))
        }
        let para = TagEdits.apply(tab, TagPath.of(tree, try titled(tree, "para")), "Change tag") { t, k in
            TagEdits.setProperties(t, k as! StructElement, TagProperties(type: "Intro", title: "para", alt: "", actualText: "", lang: "", table: nil))
        }

        XCTAssertEqual(cell.result, .done)
        XCTAssertEqual(para.result, .done)
        let again = try read(tab)
        let th = try titled(again, "Head")
        XCTAssertEqual([th.type, th.alt, th.actualText, th.lang], ["TH", "Alt words", "Spoken", "tr-TR"])
        let attributes = again.tableAttributes(th)
        XCTAssertEqual(attributes.scope, .row)
        XCTAssertEqual([attributes.rowSpan, attributes.colSpan], [2, 3])
        XCTAssertEqual(attributes.headers, ["a1", "b2"])
        XCTAssertEqual(again.standardType(try titled(again, "para").type), "P")
        XCTAssertEqual(try titled(again, "para").type, "Intro")
        XCTAssertEqual(again.roleMap["Intro"], "P")
    }

    func test_changingOnlyTheTitleOfACellKeepsHeaderIdsThatHoldASpace() async throws {
        let tab = try tab(try built { tree, root in
            let cell = try el(tree, try el(tree, try el(tree, root, "Table"), "TR"), "TD", "cell")
            tree.setTableAttributes(cell, TableAttributes(scope: nil, headers: ["Col 1", "b2"], rowSpan: nil, colSpan: nil))
        })
        let tree = try read(tab)
        let cell = try titled(tree, "cell")
        let fields = TagEdits.tableOf(scope: "", rowSpan: "", colSpan: "", headers: tree.tableAttributes(cell).headers.joined(separator: ", "))

        let outcome = TagEdits.apply(tab, TagPath.of(tree, cell), "Change tag") { t, k in
            TagEdits.setProperties(t, k as! StructElement, TagProperties(type: "TD", title: "renamed", alt: "", actualText: "", lang: "", table: fields.attributes))
        }

        XCTAssertEqual(outcome.result, .done)
        let again = try read(tab)
        XCTAssertEqual(again.tableAttributes(try titled(again, "renamed")).headers, ["Col 1", "b2"])
    }

    func test_aTypeThatDoesNotFitItsParentIsRefusedAndWritesNothing() async throws {
        let tab = try tab(try three())
        let tree = try read(tab)
        let one = try titled(tree, "one")

        let shown = TagEdits.typeRefusal(tree, one, "TD")
        let outcome = TagEdits.apply(tab, TagPath.of(tree, one), "Change tag") { t, k in
            TagEdits.setProperties(t, k as! StructElement, TagProperties(type: "TD", title: "one", alt: "", actualText: "", lang: "", table: nil))
        }

        XCTAssertEqual(shown, AccessibilityText.placementReason(TagRules.needsRow))
        XCTAssertEqual(outcome.result, .refused)
        XCTAssertEqual(outcome.reason, shown)
        XCTAssertEqual(try titled(try read(tab), "one").type, "P")
        XCTAssertEqual(TagEdits.typeRefusal(tree, one, "  "), "The type is empty.")
    }

    func test_aSpanIsAWholeNumberFromOne() async {
        for (span, refused) in [("0", true), ("x", true), ("-2", true), ("2", false), ("", false)] {
            let table = TagEdits.tableOf(scope: "", rowSpan: span, colSpan: "", headers: "")

            XCTAssertEqual(table.problem != nil, refused, span)
            XCTAssertEqual(table.attributes == nil, refused, span)
        }
    }

    func test_aLanguageThatIsNotATagIsRefused() async throws {
        let tab = try tab(try three())
        let tree = try read(tab)

        let outcome = TagEdits.apply(tab, TagPath.of(tree, try titled(tree, "one")), "Change tag") { t, k in
            TagEdits.setProperties(t, k as! StructElement, TagProperties(type: "P", title: "one", alt: "", actualText: "", lang: "not a language", table: nil))
        }

        XCTAssertEqual(outcome.result, .refused)
        XCTAssertFalse(tab.isDirty)
    }

    func test_aDropIsCheckedWithTheRuleAndPlacesTheNodeBesideOrInsideTheTarget() async throws {
        let tab = try tab(try built { tree, root in
            try el(tree, root, "P", "one")
            try el(tree, root, "P", "two")
            try el(tree, root, "Sect", "sect")
            let table = try el(tree, root, "Table", "table")
            try el(tree, table, "TR", "row")
        })
        let tree = try read(tab)
        let (one, sect, table) = (try titled(tree, "one"), try titled(tree, "sect"), try titled(tree, "table"))

        XCTAssertEqual(try TagEdits.drop(tree, one, table, .into, apply: false), AccessibilityText.placementReason(TagRules.tableKids))
        XCTAssertNil(try TagEdits.drop(tree, one, sect, .into, apply: true))
        XCTAssertEqual(titles(tree.roots[0]), ["two", "sect", "table"])
        XCTAssertEqual(titles(sect), ["one"])
        XCTAssertNil(try TagEdits.drop(tree, try titled(tree, "two"), sect, .after, apply: true))
        XCTAssertEqual(titles(tree.roots[0]), ["sect", "two", "table"])
        XCTAssertNotNil(try TagEdits.drop(tree, sect, try titled(tree, "one"), .into, apply: false))
    }

    func test_aDropFromTheTreeOnScreenIsTriedAgainstTheOpenDocumentsTree() async throws {
        let tab = try tab(try three())
        let shown = try read(tab)
        let (path, target) = (TagPath.of(shown, try titled(shown, "one")), TagPath.of(shown, try titled(shown, "three")))

        let outcome = TagEdits.apply(tab, path, "Move tag") { t, k in try TagEdits.drop(t, k!, target.find(t)!, .after, apply: true) }

        XCTAssertEqual(outcome.result, .done)
        XCTAssertEqual(titles(try titled(try read(tab), "sect")), ["two", "three", "one"])
    }

    func test_aNodeThatMovedSinceTheTreeWasReadIsNotTakenForAnother() async throws {
        let tab = try tab(try three())
        let shown = try read(tab)
        let path = TagPath.of(shown, try titled(shown, "two"))
        XCTAssertEqual(try command(tab, "two", .moveDown).result, .done)

        let outcome = TagEdits.apply(tab, path, "Move tag down") { t, k in try TagEdits.run(t, k!, .moveDown) }

        XCTAssertEqual(outcome.result, .gone)
        XCTAssertEqual(tab.session.undoLabel, "Move tag down")
    }

    func test_deletingAsArtifactTakesTheContentOutOfTheTreeAndTheReadingOrder() async throws {
        let tab = try tab(try auto())
        let tree = try read(tab)
        let paragraph = try XCTUnwrap(tree.elements.first { $0.type == "P" })
        let text = ReadingOrder.export(tab.document)
        let count = tree.elements.count

        let outcome = TagEdits.apply(tab, TagPath.of(tree, paragraph), "Delete tag as artifact") { t, k in try TagEdits.run(t, k!, .deleteAsArtifact) }

        XCTAssertEqual(outcome.result, .done)
        XCTAssertEqual(try read(tab).elements.count, count - 1)
        XCTAssertLessThan(ReadingOrder.export(tab.document).count, text.count)
        XCTAssertTrue(try tab.undo())
        XCTAssertEqual(ReadingOrder.export(tab.document), text)
    }

    func test_markingOneContentNodeAsArtifactLeavesItsElementsOtherContent() async throws {
        let tab = try tab(try auto())
        let tree = try read(tab)
        let content = try XCTUnwrap(tree.contents.first)
        XCTAssertTrue(TagEdits.applies(tree, content, .markAsArtifact))
        let count = tree.contents.count

        let outcome = TagEdits.apply(tab, TagPath.of(tree, content), "Mark as artifact") { t, k in try TagEdits.run(t, k!, .markAsArtifact) }

        XCTAssertEqual(outcome.result, .done)
        XCTAssertEqual(try read(tab).contents.count, count - 1)
    }

    func test_aTextSelectionIsTaggedAsANewElementUnderTheChosenOne() async throws {
        let tab = try tab(try auto())
        let tree = try read(tab)
        let runs = [SelectedRun(page: 0, range: wholePage(tab), text: "text", quads: [])]
        let paragraphs = tree.elements.filter { $0.type == "P" }.count

        let outcome = TagEdits.apply(tab, TagPath.of(tree, tree.roots[0]), "Tag selection") { t, k in try TagEdits.tagSelection(t, k, "Div", runs) }

        XCTAssertEqual(outcome.result, .done, outcome.reason ?? "")
        let again = try read(tab)
        let divs = again.elements.filter { $0.type == "Div" }
        XCTAssertEqual(divs.count, 1)
        XCTAssertTrue(divs[0].parent === again.roots[0])
        XCTAssertFalse(divs[0].kids.isEmpty)
        XCTAssertEqual(tab.session.undoLabel, "Tag selection")
        XCTAssertLessThan(again.elements.filter { $0.type == "P" }.count, paragraphs)
    }

    func test_aTextSelectionCanBeMarkedAsArtifactInOneStep() async throws {
        let tab = try tab(try auto())
        let count = try read(tab).contents.count
        let text = ReadingOrder.export(tab.document)
        let runs = [SelectedRun(page: 0, range: wholePage(tab), text: "text", quads: [])]

        let outcome = TagEdits.apply(tab, nil, "Mark as artifact") { t, _ in try TagEdits.selectionAsArtifact(t, runs) }

        XCTAssertEqual(outcome.result, .done, outcome.reason ?? "")
        XCTAssertLessThan(try read(tab).contents.count, count)
        XCTAssertLessThan(ReadingOrder.export(tab.document).count, text.count)
        XCTAssertEqual(tab.session.undoLabel, "Mark as artifact")
    }

    func test_aSelectionNothingCanBeTaggedFromIsRefusedWithItsReason() async throws {
        let tab = try tab(try auto())
        let tree = try read(tab)

        let outcome = TagEdits.apply(tab, TagPath.of(tree, tree.roots[0]), "Tag selection") { t, k in try TagEdits.tagSelection(t, k, "Div", []) }

        XCTAssertEqual(outcome.result, .refused)
        XCTAssertEqual(outcome.reason, AccessibilityText.contentReason(TagContent.emptySelection))
    }

    func test_aRestrictedOrEncryptedFileIsReadOnlyAndNothingIsWritten() async throws {
        let document = try PdfDocument.open(try auto())
        let open = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: PdfPermissions.all, strength: .aes256,
                                      firstId: [UInt8](repeating: 7, count: 16))
        let encrypted = try document.saveRewrite(PdfSaveOptions(security: open))

        for bytes in [try restricted(), encrypted] {
            let tab = try tab(bytes)
            let tree = try read(tab)
            XCTAssertNotNil(TagEdits.readOnlyReason(tab.document, tree))
            let outcome = TagEdits.apply(tab, TagPath.of(tree, tree.roots[0]), "Move tag up") { t, k in try TagEdits.run(t, k!, .moveUp) }
            XCTAssertEqual(outcome.result, .refused)
            XCTAssertFalse(tab.isDirty)
        }
    }

    func test_theFilterKeepsMatchesAndTheTagsAboveThem() async throws {
        let tab = try tab(try built { tree, root in
            let sect = try el(tree, root, "Sect", "intro")
            try el(tree, sect, "P", "plain")
            try el(tree, sect, "H2", "Chapter one")
            let table = try el(tree, root, "Table", "data")
            try el(tree, table, "TR", "row")
            try el(tree, root, "Figure").alt = "A grey square"
        })
        let tree = try read(tab)

        let byType = try XCTUnwrap(TagFilter.of(tree, "h2"))
        let byText = try XCTUnwrap(TagFilter.of(tree, " SQUARE "))
        let types = { (filter: TagFilter) in tree.elements.filter { filter.shows($0) }.map(\.type).sorted() }

        XCTAssertEqual(byType.matches, 1)
        XCTAssertEqual(types(byType), ["Document", "H2", "Sect"])
        XCTAssertEqual(types(byText), ["Document", "Figure"])
        XCTAssertNil(TagFilter.of(tree, "  "))
        XCTAssertEqual(try XCTUnwrap(TagFilter.of(tree, "nothing like it")).matches, 0)
    }

    func test_theFilterStopsAtItsLimitAndSaysSo() async throws {
        let document = try PdfDocument.open(Pdfs.text())
        let tree = StructureTree.create(document)
        let root = try el(tree, nil, "Document")
        for i in 0..<(TagFilter.limit + 20) { try el(tree, root, "P", "word \(i)") }

        let all = try XCTUnwrap(TagFilter.of(tree, "word"))

        XCTAssertTrue(all.isCapped)
        XCTAssertEqual(all.matches, TagFilter.limit)
        XCTAssertFalse(try XCTUnwrap(TagFilter.of(tree, "word 1")).isCapped)
    }

    func test_contentAndObjectNodesHaveTheirOwnLabels() async throws {
        let tree = StructureTree.create(try PdfDocument.open(Pdfs.text()))

        XCTAssertEqual(TagLabels.of(StructContent(0, 3), tree), "Marked content, page 1")
        XCTAssertEqual(TagLabels.of(StructContent(-1, 3), tree), "Marked content")
        XCTAssertEqual(TagLabels.of(StructObject(1, PdfReference(5, 0)), tree), "Annotation, page 2")
    }

    // MARK: The panel model

    private struct Shown {
        let model: AccessibilityModel
        let rig: ToolRig
    }

    private func show(_ bytes: [UInt8]) async throws -> Shown {
        let rig = try ToolRig(bytes)
        let model = AccessibilityModel()
        rig.attach(model)
        model.setView(.tags)
        await waitUntil { !model.tagRows.isEmpty }
        return Shown(model: model, rig: rig)
    }

    private func openAll(_ model: AccessibilityModel) {
        for _ in 0..<12 {
            guard let closed = model.tagRows.first(where: { $0.hasKids && !$0.isOpen }) else { return }
            model.toggle(closed)
        }
    }

    private func row(_ model: AccessibilityModel, _ title: String) throws -> TagRow {
        try XCTUnwrap(model.tagRows.first { ($0.kid as? StructElement)?.title == title }, title)
    }

    private func order(_ model: AccessibilityModel) -> [String] {
        model.tagRows.compactMap { ($0.kid as? StructElement)?.title }
    }

    func test_theLinesAreTheOpenNodesAndAToggleOpensOrClosesOne() async throws {
        let s = try await show(try three())
        XCTAssertEqual(s.model.tagRows.count, 1)
        XCTAssertTrue(s.model.tagRows[0].hasKids)
        XCTAssertFalse(s.model.tagRows[0].isOpen)

        openAll(s.model)

        XCTAssertEqual(order(s.model), ["sect", "one", "two", "three"])
        XCTAssertEqual(s.model.tagRows.map(\.depth), [0, 1, 2, 2, 2])
        XCTAssertEqual(s.model.tagsNote, "5 tags. Pick one to go to its page.")
        s.model.toggle(s.model.tagRows[0])
        XCTAssertEqual(s.model.tagRows.count, 1)
    }

    func test_moreThanTwoHundredKidsEndInOneLineThatSaysHowManyAreLeft() async throws {
        let s = try await show(try built { tree, root in
            let list = try el(tree, root, "L")
            for _ in 0..<230 { try el(tree, list, "LI") }
        })
        openAll(s.model)

        XCTAssertEqual(s.model.tagRows.count, 1 + 1 + 200 + 1)
        XCTAssertTrue(s.model.tagRows.last!.isMore)
        XCTAssertEqual(s.model.tagRows.last!.label, "30 more")
    }

    func test_aPickedNodeTakesTheViewerToItsPage() async throws {
        let s = try await show(try auto())
        openAll(s.model)
        let paragraph = try XCTUnwrap(s.model.tagRows.first { ($0.kid as? StructElement)?.type == "P" })

        s.model.select(paragraph)

        XCTAssertEqual(s.rig.viewer.sent, [FigureFinder.pageOf(paragraph.kid as! StructElement)])
        XCTAssertEqual(s.model.selectedTag, paragraph.id)
        XCTAssertTrue(s.model.showsEditor)
    }

    func test_aMoveFromThePanelIsOneStepAndTheTreeComesBackWithTheSameNodeAndOpenTags() async throws {
        let s = try await show(try three())
        openAll(s.model)
        s.model.select(try row(s.model, "two"))
        XCTAssertTrue(s.model.canRun(.moveDown))

        s.model.run(.moveDown)
        await waitUntil { self.order(s.model) == ["sect", "one", "three", "two"] }

        XCTAssertEqual(s.rig.tab.session.undoLabel, "Move tag down")
        let picked = try XCTUnwrap(s.model.pickedRow?.kid as? StructElement)
        XCTAssertEqual(picked.title, "two")
        XCTAssertTrue(s.model.tagRows[0].isOpen)
    }

    func test_aCommandThatDoesNotFitSaysWhyAndWritesNothing() async throws {
        let s = try await show(try three())
        openAll(s.model)
        s.model.select(try row(s.model, "two"))

        s.model.run(.indent)

        XCTAssertEqual(s.model.tagMessage, AccessibilityText.placementReason(TagRules.textKids))
        XCTAssertFalse(s.rig.tab.isDirty)
    }

    func test_theEditorShowsTheRulesReasonBesideTheFieldAndAppliesAValidChange() async throws {
        let s = try await show(try three())
        openAll(s.model)
        s.model.select(try row(s.model, "one"))
        XCTAssertFalse(s.model.canApplyForm)

        s.model.form.type = "TD"
        s.model.form.title = "first"

        XCTAssertEqual(s.model.formMessage, AccessibilityText.placementReason(TagRules.needsRow))
        XCTAssertFalse(s.model.canApplyForm)

        s.model.form.type = "H2"
        XCTAssertEqual(s.model.formMessage, "")
        XCTAssertTrue(s.model.canApplyForm)
        s.model.applyForm()

        XCTAssertEqual(s.rig.tab.session.undoLabel, "Change tag")
        let written = try XCTUnwrap(try read(s.rig.tab).elements.first { $0.title == "first" })
        XCTAssertEqual(written.type, "H2")
    }

    func test_aLanguageThatIsNotATagStopsApplyAndSaysSo() async throws {
        let s = try await show(try three())
        openAll(s.model)
        s.model.select(try row(s.model, "one"))

        s.model.form.lang = "not a language"

        XCTAssertEqual(s.model.formMessage, "Write the language as a tag such as en-US or tr-TR.")
        XCTAssertFalse(s.model.canApplyForm)
    }

    func test_theTableFieldsShowOnlyForCells() async throws {
        let s = try await show(try built { tree, root in
            let row = try el(tree, try el(tree, root, "Table"), "TR")
            try el(tree, row, "TD", "cell")
        })
        openAll(s.model)

        s.model.select(try row(s.model, "cell"))
        XCTAssertTrue(s.model.editsCell)

        s.model.select(s.model.tagRows[0])
        XCTAssertFalse(s.model.editsCell)
    }

    func test_aPickedElementIsOutlinedOnThePageAndTheOutlineGoesWhenItIsLeft() async throws {
        let s = try await show(try auto())
        openAll(s.model)
        let paragraph = try XCTUnwrap(s.model.tagRows.first { ($0.kid as? StructElement)?.type == "P" })
        let page = FigureFinder.pageOf(paragraph.kid as! StructElement)

        s.model.select(paragraph)
        await waitUntil { !s.rig.viewer.overlay(page).items.isEmpty }

        s.model.setView(.figures)
        XCTAssertTrue(s.rig.viewer.overlay(page).items.isEmpty)
    }

    func test_markedContentIsAListedNodeThatCanBeMarkedAsArtifact() async throws {
        let s = try await show(try auto())
        openAll(s.model)
        let content = try XCTUnwrap(s.model.tagRows.first { $0.kid is StructContent })
        s.model.select(content)
        XCTAssertTrue(content.label.hasPrefix("Marked content, page 1"))
        XCTAssertTrue(s.model.canRun(.markAsArtifact))
        XCTAssertFalse(s.model.canRun(.delete))
        XCTAssertFalse(s.model.showsEditor)
        let before = try read(s.rig.tab).contents.count

        s.model.run(.markAsArtifact)

        XCTAssertEqual(s.rig.tab.session.undoLabel, "Mark as artifact")
        XCTAssertEqual(try read(s.rig.tab).contents.count, before - 1)
    }

    func test_thePagesTextSelectionIsTaggedUnderThePickedElement() async throws {
        let s = try await show(try auto())
        s.rig.viewer.hasSelection = true
        s.rig.viewer.runs = [SelectedRun(page: 0, range: wholePage(s.rig.tab), text: "text", quads: [])]
        s.model.select(s.model.tagRows[0])
        s.model.tagAs = "Div"

        await s.model.tagSelection()

        XCTAssertEqual(s.rig.tab.session.undoLabel, "Tag selection")
        XCTAssertTrue(try read(s.rig.tab).elements.contains { $0.type == "Div" })
    }

    func test_withoutASelectionTaggingItSaysSoAndChangesNothing() async throws {
        let s = try await show(try auto())
        s.model.select(s.model.tagRows[0])

        await s.model.tagSelection()

        XCTAssertEqual(s.model.tagMessage, "Select the text on the page first.")
        XCTAssertFalse(s.rig.tab.isDirty)
    }

    func test_aDrawnAreaIsTaggedUnderThePickedElement() async throws {
        let s = try await show(try auto())
        let tree = try read(s.rig.tab)
        let paragraph = try XCTUnwrap(tree.elements.first { $0.type == "P" })
        let box = try XCTUnwrap(tree.boxes(paragraph).boxes.first { $0.pageIndex == 0 }).rect
        s.model.select(s.model.tagRows[0])

        s.model.tagArea(0, PdfRect(box.left - 1, box.bottom - 1, box.right + 1, box.top + 1), "Div")

        XCTAssertEqual(s.rig.tab.session.undoLabel, "Tag area", s.model.tagMessage)
        XCTAssertTrue(try read(s.rig.tab).elements.contains { $0.type == "Div" })
    }

    func test_theFilterShowsMatchesWithTheirParentsOpenAndTheWholeTreeAgainWhenCleared() async throws {
        let s = try await show(try built { tree, root in
            let sect = try el(tree, root, "Sect", "intro")
            try el(tree, sect, "P", "plain")
            try el(tree, root, "Figure").alt = "A grey square"
        })

        s.model.tagFilter = "square"

        XCTAssertEqual(s.model.tagRows.map(\.depth), [0, 1])
        XCTAssertEqual((s.model.tagRows[1].kid as? StructElement)?.type, "Figure")
        XCTAssertTrue(s.model.tagRows[0].isOpen)
        XCTAssertEqual(s.model.tagsNote, "1 tags match.")

        s.model.tagFilter = ""
        openAll(s.model)

        XCTAssertEqual(order(s.model), ["intro", "plain"])
        XCTAssertEqual(s.model.tagRows.count, 4)
        XCTAssertEqual(s.model.tagsNote, "4 tags. Pick one to go to its page.")
    }

    func test_aDropOnAnotherLineMovesTheNodeAndARefusedDropSaysWhy() async throws {
        let s = try await show(try built { tree, root in
            try el(tree, root, "P", "one")
            try el(tree, root, "Sect", "sect")
            let table = try el(tree, root, "Table", "table")
            try el(tree, table, "TR", "row")
        })
        openAll(s.model)
        let one = try row(s.model, "one")

        XCTAssertFalse(s.model.drop(one.id, onto: try row(s.model, "table"), zone: .into))
        XCTAssertEqual(s.model.tagMessage, AccessibilityText.placementReason(TagRules.tableKids))
        XCTAssertFalse(s.rig.tab.isDirty)

        XCTAssertTrue(s.model.drop(one.id, onto: try row(s.model, "sect"), zone: .into))
        await waitUntil { self.order(s.model) == ["sect", "one", "table", "row"] }
        XCTAssertEqual(s.rig.tab.session.undoLabel, "Move tag")
    }

    func test_reorderingAListLineMovesItBeforeTheLineAtTheNewPlace() async throws {
        let s = try await show(try three())
        openAll(s.model)

        s.model.moveRows(from: IndexSet(integer: 3), to: 5)
        await waitUntil { self.order(s.model) == ["sect", "one", "three", "two"] }

        XCTAssertEqual(s.rig.tab.session.undoLabel, "Move tag")
    }

    func test_aRestrictedFileShowsWhyItIsReadOnlyAndTheCommandsDoNothing() async throws {
        let s = try await show(try restricted())
        openAll(s.model)
        let node = try XCTUnwrap(s.model.tagRows.first { ($0.kid as? StructElement)?.type == "P" })
        s.model.select(node)

        XCTAssertNotNil(s.model.tagReadOnly)
        XCTAssertFalse(s.model.canRun(.moveDown))
        XCTAssertFalse(s.model.canApplyForm)

        s.model.run(.moveDown)

        XCTAssertEqual(s.model.tagMessage, s.model.tagReadOnly)
        XCTAssertFalse(s.rig.tab.isDirty)
    }

    func test_detachLetsGoOfTheTagState() async throws {
        let s = try await show(try three())
        openAll(s.model)
        s.model.select(try row(s.model, "one"))
        s.model.tagFilter = "one"

        s.model.detach()

        XCTAssertTrue(s.model.tagRows.isEmpty)
        XCTAssertNil(s.model.selectedTag)
        XCTAssertEqual(s.model.tagFilter, "")
        XCTAssertFalse(s.model.showsEditor)
    }
}
