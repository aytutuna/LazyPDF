import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/standards/AccessibilityRowsTests.cs: the rows of the accessibility check and the
// fixes they offer, against the engine's checker.

final class AccessibilityRowsTests: XCTestCase {
    private func rows(_ document: PdfDocument, _ fileName: String = "Notes.pdf") throws -> [CheckRow] {
        try AccessibilityChecker.check(document).items.map { item in
            let value = item.rule == .title ? AccessibilityEdits.titleOf(document, fileName)
                : item.rule == .language ? AccessibilityEdits.languageOf(document) : ""
            return CheckRow(item, value: value)
        }
    }

    private func row(_ rows: [CheckRow], _ rule: AccessibilityRule) throws -> CheckRow {
        try XCTUnwrap(rows.first { $0.name == AccessibilityText.name(rule) })
    }

    func test_anUntaggedFileFailsTheTagCheckAndOffersToAddTags() throws {
        let document = try PdfDocument.open(Pdfs.text())

        let tagged = try row(rows(document), .tagged)

        XCTAssertEqual(tagged.level, .failed)
        XCTAssertEqual(tagged.action, .addTags)
        XCTAssertEqual(tagged.actionText, "Add tags")
    }

    func test_colourContrastIsLeftToAPersonWithNoButton() throws {
        let contrast = try row(rows(PdfDocument.open(Pdfs.text())), .contrast)

        XCTAssertEqual(contrast.status, "Needs a person")
        XCTAssertEqual(contrast.action, .none)
    }

    func test_theTitleBoxStartsWithTheFileNameAndSavingItFixesTheCheck() throws {
        let document = try PdfDocument.open(Pdfs.text())
        let title = try row(rows(document, "Lease agreement.pdf"), .title)
        XCTAssertEqual(title.level, .failed)
        XCTAssertEqual(title.value, "Lease agreement")

        title.value = "Lease for the flat"
        XCTAssertTrue(try AccessibilityEdits.apply(document, title))

        let after = try AccessibilityChecker.check(PdfDocument.open(document.saveIncremental()))[.title]
        XCTAssertEqual(after.status, .passed)
        XCTAssertEqual(DocumentMetadata.read(document).title, "Lease for the flat")
    }

    func test_anEmptyTitleChangesNothing() throws {
        let document = try PdfDocument.open(Pdfs.text())
        let title = try row(rows(document), .title)
        title.value = "  "

        XCTAssertFalse(try AccessibilityEdits.apply(document, title))
    }

    func test_theLanguageIsSetFromItsBoxAndABadTagIsRefused() throws {
        let document = try PdfDocument.open(Pdfs.text())
        let language = try row(rows(document), .language)

        language.value = "not a tag!"
        XCTAssertThrowsError(try AccessibilityEdits.apply(document, language)) { XCTAssertTrue($0 is ArgumentException) }

        language.value = "tr-TR"
        XCTAssertTrue(try AccessibilityEdits.apply(document, language))
        XCTAssertEqual(AccessibilityEdits.languageOf(document), "tr-TR")
    }

    @MainActor
    func test_aSavedFixIsOneUndoStepOnTheTab() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!
        let language = try row(rows(tab.document), .language)
        language.value = "en-GB"

        XCTAssertTrue(try AccessibilityEdits.apply(tab.document, language))
        XCTAssertTrue(try tab.commit("Language"))

        XCTAssertEqual(tab.session.undoLabel, "Language")
        try tab.undo()
        XCTAssertEqual(PdfText.read(tab.document, tab.document.catalog, "Lang") ?? "", "")
    }

    func test_addTagsIsOnlyOfferedWhereTheTaggerWillTakeTheFile() throws {
        let item = try AccessibilityChecker.check(PdfDocument.open(Pdfs.text()))[.tagged]

        XCTAssertEqual(CheckRow(item).action, .addTags)
        XCTAssertEqual(CheckRow(item, value: "", canAddTags: true).action, .addTags)
        XCTAssertEqual(CheckRow(item, value: "", canAddTags: false).action, .none)
    }

    func test_aTaggedMarkWithoutATreeIsNotSomethingTheTaggerWillTake() throws {
        let plain = try PdfDocument.open(Pdfs.text())
        XCTAssertTrue(AccessibilityEdits.canAddTags(plain))

        let marked = try PdfDocument.open(Pdfs.text())
        let mark = PdfDictionary()
        mark["Marked"] = PdfBoolean(true)
        marked.catalog["MarkInfo"] = mark
        XCTAssertFalse(AccessibilityEdits.canAddTags(marked))
        XCTAssertTrue(try AutoTagger.tag(marked).alreadyTagged)

        let tagged = try PdfDocument.open(Pdfs.text())
        _ = try AutoTagger.tag(tagged)
        XCTAssertFalse(AccessibilityEdits.canAddTags(tagged))
    }

    func test_anEditedBoxIsToldFromOneThatOnlyHoldsWhatItStartedWith() throws {
        let document = try PdfDocument.open(Pdfs.text())
        let title = try row(rows(document, "Lease agreement.pdf"), .title)
        XCTAssertFalse(title.edited)

        title.value = " Lease agreement "
        XCTAssertFalse(title.edited)

        title.value = "Lease for the flat"
        XCTAssertTrue(title.edited)
    }

    func test_thePlaceButtonGoesToEachPageInTurn() {
        let item = AccessibilityItem(.figureAlt, "Figures", .failed, "Two figures.",
                                     [AccessibilityPlace(2, nil), AccessibilityPlace(-1, nil), AccessibilityPlace(5, nil), AccessibilityPlace(2, nil)], .none)
        let row = CheckRow(item)

        XCTAssertTrue(row.hasPlaces)
        XCTAssertEqual(row.placeText, "Go to page 3")
        XCTAssertEqual(row.nextPage(), 2)
        XCTAssertEqual(row.placeText, "Go to page 6")
        XCTAssertEqual(row.nextPage(), 5)
        XCTAssertEqual(row.nextPage(), 2)
    }

    func test_aRowReadsAsItsNameItsStatusAndItsMessage() {
        let item = AccessibilityItem(.links, "Links have text", .passed, "Every link is tagged and has text.", [], .none)

        XCTAssertEqual(CheckRow(item).summary, "Links have text, Passed. Every link is tagged and has text.")
    }
}
