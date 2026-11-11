import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/Pages/PageEditsTests.cs: what the Pages panel does to a document, against the real
// engine. The tests of TilePanel.Locate are left out: the grid is a LazyVGrid here, which has no panel of ours to test, and
// where a drop lands is checked with the marks of PageGrid in PageGridTests.

@MainActor
final class PageEditsTests: XCTestCase {
    private func open(_ pages: Int = 5) throws -> PdfDocument {
        try PdfDocument.open(Pdfs.text(pages))
    }

    private func text(_ document: PdfDocument, _ page: Int) -> String {
        String(bytes: document.pages[page].contents(), encoding: .isoLatin1) ?? ""
    }

    func test_aNewPageGoesWhereTheChoiceSays() {
        XCTAssertEqual(PageEdits.insertAt(.afterSelection, [1, 2], 5), 3)
        XCTAssertEqual(PageEdits.insertAt(.beforeSelection, [1, 2], 5), 1)
        XCTAssertEqual(PageEdits.insertAt(.atStart, [1, 2], 5), 0)
        XCTAssertEqual(PageEdits.insertAt(.atEnd, [1, 2], 5), 5)
    }

    func test_withNothingSelectedANewPageGoesLast() {
        XCTAssertEqual(PageEdits.insertAt(.afterSelection, [], 5), 5)
        XCTAssertEqual(PageEdits.insertAt(.beforeSelection, [], 5), 5)
    }

    func test_aBlankPageTakesTheSizeOfThePageBeforeIt() throws {
        let document = try open(2)
        try PageOperations.setBox(document, [0], .crop, PdfRect(0, 0, 300, 400))
        let size = PageEdits.neighbourSize(document, 1)

        try PageOperations.insertBlank(document, 1, size.width, size.height)

        XCTAssertEqual(document.pages.count, 3)
        let shown = PageGeometry(document.pages[1])
        XCTAssertEqual(shown.width, 300, accuracy: 0.1)
        XCTAssertEqual(shown.height, 400, accuracy: 0.1)
    }

    func test_movedPagesAreFoundWhereTheyLand() {
        XCTAssertEqual(PageEdits.movedTo([1, 2], 4), [2, 3])
        XCTAssertEqual(PageEdits.movedTo([3], 0), [0])
        XCTAssertEqual(PageEdits.movedTo([0, 4], 2), [1, 2])
        XCTAssertEqual(PageEdits.movedTo([1], 5), [4])
    }

    func test_theLandingPlaceMatchesWhatMoveDoes() throws {
        let document = try open(6)
        let marked = (0..<6).map { text(document, $0) }

        try PageOperations.move(document, [1, 4], 3)

        let landed = PageEdits.movedTo([1, 4], 3)
        XCTAssertEqual(text(document, landed[0]), marked[1])
        XCTAssertEqual(text(document, landed[1]), marked[4])
    }

    func test_eachChosenRunStepsOnAndPagesApartStayApart() throws {
        let document = try open(6)
        let marked = (0..<6).map { text(document, $0) }

        try PageEdits.nudge(document, [2, 5], -1)

        XCTAssertEqual((0..<6).map { text(document, $0) }, [marked[0], marked[2], marked[1], marked[3], marked[5], marked[4]])
        XCTAssertEqual(PageEdits.nudged([2, 5], -1, 6), [1, 4])
        XCTAssertEqual(PageEdits.nudged([0, 3], 1, 6), [1, 4])
    }

    func test_aRunAtTheEdgeStaysWhereItIs() throws {
        let document = try open(6)
        let marked = (0..<6).map { text(document, $0) }

        try PageEdits.nudge(document, [0, 1], -1)
        try PageEdits.nudge(document, [4, 5], 1)

        XCTAssertEqual((0..<6).map { text(document, $0) }, marked)
        XCTAssertEqual(PageEdits.nudged([0, 1], -1, 6), [0, 1])
        XCTAssertEqual(PageEdits.nudged([4, 5], 1, 6), [4, 5])
        XCTAssertFalse(PageEdits.canNudge([0, 1], -1, 6))
        XCTAssertFalse(PageEdits.canNudge([4, 5], 1, 6))
        XCTAssertTrue(PageEdits.canNudge([0, 3], -1, 6))
        XCTAssertTrue(PageEdits.canNudge([0, 3], 1, 6))
    }

    func test_nudgingLaterMovesTheLastRunFirst() throws {
        let document = try open(6)
        let marked = (0..<6).map { text(document, $0) }

        try PageEdits.nudge(document, [0, 3], 1)

        XCTAssertEqual((0..<6).map { text(document, $0) }, [marked[1], marked[0], marked[2], marked[4], marked[3], marked[5]])
    }

    func test_duplicatedPagesAreFoundBesideTheirCopies() throws {
        let document = try open(4)
        let marked = (0..<4).map { text(document, $0) }

        try PageOperations.duplicate(document, [1, 3])

        XCTAssertEqual(document.pages.count, 6)
        XCTAssertEqual(PageEdits.duplicated([3, 1]), [1, 2, 4, 5])
        XCTAssertEqual(text(document, 1), marked[1])
        XCTAssertEqual(text(document, 2), marked[1])
        XCTAssertEqual(text(document, 5), marked[3])
    }

    func test_replacingPagesPutsTheOthersInTheirPlace() throws {
        let target = try open(5)
        let source = try PdfDocument.open(Pdfs.text(3, "From the other file."))
        let keep = text(target, 4)

        try PageEdits.replace(target, [1, 2], source, [2, 0])

        XCTAssertEqual(target.pages.count, 5)
        XCTAssertEqual(text(target, 1), text(source, 2))
        XCTAssertEqual(text(target, 2), text(source, 0))
        XCTAssertEqual(text(target, 4), keep)
    }

    func test_aDrawnBoxBecomesTheCropBoxOfEveryPageThroughItsOwnTurn() throws {
        let document = try open(2)
        PageOperations.rotate(document, [1], 90)
        let upright = PageGeometry(document.pages[0])
        let box = DisplayRect(upright.width / 8, upright.height / 8, upright.width / 4, upright.height / 4)

        try PageEdits.crop(document, [0, 1], box)

        let first = PageGeometry(document.pages[0])
        let second = PageGeometry(document.pages[1])
        XCTAssertEqual(first.width, box.width, accuracy: 0.1)
        XCTAssertEqual(first.height, box.height, accuracy: 0.1)
        XCTAssertEqual(second.width, box.width, accuracy: 0.1)
        XCTAssertEqual(second.height, box.height, accuracy: 0.1)
        XCTAssertEqual(document.pages[1].rotate, 90)
    }

    func test_labelsCoverTheSelectionAndLeaveTheRestAsTheyWere() throws {
        let document = try open(8)
        try PdfPageLabels.write(document, [PageLabelRange(0, .lowerRoman), PageLabelRange(4, .decimal)])

        try PageEdits.relabel(document, 1, 2, .upperLetters, "App-", 3)

        XCTAssertEqual(PdfPageLabels.labels(document), ["i", "App-C", "App-D", "iv", "1", "2", "3", "4"])
    }

    func test_labelsOnTheLastPagesNeedNoRestoringRange() throws {
        let document = try open(4)

        try PageEdits.relabel(document, 2, 3, .decimal, "", 10)

        XCTAssertEqual(PdfPageLabels.labels(document), ["1", "2", "10", "11"])
    }

    func test_clearingLabelsRestoresPlainNumbers() throws {
        let document = try open(3)
        try PageEdits.relabel(document, 0, 2, .upperRoman, "", 1)

        try PageEdits.clearLabels(document)

        XCTAssertEqual(PdfPageLabels.labels(document), ["1", "2", "3"])
    }

    func test_resizingKeepsEachPagesOrientation() throws {
        let document = try open(3)
        PageOperations.rotate(document, [1], 90)

        try PageEdits.resizeTo(document, [0, 1, 2], 595.276, 841.89, .changeBox)

        let portrait = PageGeometry(document.pages[0])
        let landscape = PageGeometry(document.pages[1])
        XCTAssertEqual(portrait.width, 595.276, accuracy: 0.1)
        XCTAssertEqual(portrait.height, 841.89, accuracy: 0.1)
        XCTAssertEqual(landscape.width, 841.89, accuracy: 0.1)
        XCTAssertEqual(landscape.height, 595.276, accuracy: 0.1)
    }

    func test_aCopyForAnotherThreadHasTheCommittedPagesOnly() throws {
        let rig = try ToolRig(Pdfs.text(3))
        try PageOperations.delete(rig.tab.document, [0])
        try rig.tab.commit("Delete pages")
        PageOperations.rotate(rig.tab.document, [0], 90)

        let copy = try PageEdits.reopen(rig.tab, rig.host)

        XCTAssertEqual(copy.pages.count, 2)
        XCTAssertEqual(copy.pages[0].rotate, 0)
    }

    func test_aCopyOfAnEncryptedFileOpensWithTheTabsPassword() throws {
        let rig = try ToolRig(PagesPdfs.locked(2), password: "secret")

        let copy = try PageEdits.reopen(rig.tab, rig.host)

        XCTAssertEqual(copy.pages.count, 2)
    }

    func test_aDeleteThatKeepsNoPageIsRefusedBeforeAnythingChanges() throws {
        let document = try open(2)

        XCTAssertThrowsError(try PageOperations.delete(document, [0, 1]))

        XCTAssertEqual(document.pages.count, 2)
    }

    func test_numberingTheFirstPagesOfAFileWithoutLabelsKeepsTheNumbersOfTheRest() throws {
        let document = try open(10)

        try PageEdits.relabel(document, 0, 2, .lowerRoman, "", 1)

        XCTAssertEqual(PdfPageLabels.labels(document), ["i", "ii", "iii", "4", "5", "6", "7", "8", "9", "10"])
    }

    func test_numberingPagesInsideAFileWithoutLabelsKeepsTheNumbersAroundThem() throws {
        let document = try open(6)

        try PageEdits.relabel(document, 2, 3, .upperLetters, "", 1)

        XCTAssertEqual(PdfPageLabels.labels(document), ["1", "2", "A", "B", "5", "6"])
    }

    func test_aBoxThatMissesALaterPageLeavesNoCropOnTheEarlierOnesOnceDiscarded() throws {
        let rig = try ToolRig(Pdfs.text(2))
        try PageOperations.setBox(rig.tab.document, [1], .crop, PdfRect(0, 0, 100, 100))
        try rig.tab.commit("Crop")
        let before = PageGeometry(rig.tab.document.pages[0])
        let box = DisplayRect(before.width / 2, before.height / 2, before.width / 4, before.height / 4)

        XCTAssertThrowsError(try PageEdits.crop(rig.tab.document, [0, 1], box))
        XCTAssertTrue(rig.tab.document.hasChanges)
        PageJobs.refuse(rig.host, rig.tab)

        XCTAssertFalse(rig.tab.document.hasChanges)
        XCTAssertFalse(try rig.tab.commit("Later"))
        XCTAssertEqual(PageGeometry(rig.tab.document.pages[0]).width, before.width, accuracy: 0.1)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Pages not changed"])
    }

    func test_thePaperListNamesGoThroughTheCatalog() {
        XCTAssertTrue(PaperSize.all.contains { $0.name == L10n.t("Letter") })
        XCTAssertTrue(PaperSize.all.contains { $0.name == L10n.t("Legal") })
    }

    func test_aFileOpenedWithoutTheOwnerRightsIsLockedOnlyWhenItRestrictsSomething() throws {
        let restricted = try PdfDocument.open(Pdfs.restricted(.print))
        let allowed = try PdfDocument.open(Pdfs.restricted(.all))
        let owner = try PdfDocument.open(Pdfs.restricted(.print), password: "owner")

        XCTAssertTrue(CopyRules.locked(restricted))
        XCTAssertFalse(CopyRules.locked(allowed))
        XCTAssertFalse(CopyRules.locked(owner))
        XCTAssertFalse(CopyRules.locked(try open()))
    }

    func test_aRefusedCopyIsReportedAndAFreeOneIsNot() throws {
        let host = PagesHost()

        XCTAssertTrue(CopyRules.refused(try PdfDocument.open(Pdfs.restricted(.print)), host))
        XCTAssertFalse(CopyRules.refused(try open(), host))

        XCTAssertEqual(host.problems.map(\.title), ["File is protected"])
    }

    func test_aNoticeIsGivenOnlyWhenTheSourceWasEncrypted() throws {
        let host = PagesHost()

        CopyRules.noteUnprotected(try open(), host)
        CopyRules.noteUnprotected(try PdfDocument.open(Pdfs.restricted(.all)), host)

        XCTAssertEqual(host.notices.map(\.title), ["Copy is not protected"])
    }

    func test_aTypedNumberFollowsTheDecimalMarkOfTheLanguage() {
        XCTAssertEqual(PageEdits.number("2.5", locale: Locale(identifier: "en_US")), 2.5)
        XCTAssertEqual(PageEdits.number(" 10 ", locale: Locale(identifier: "en_US")), 10)
        XCTAssertNil(PageEdits.number("many", locale: Locale(identifier: "en_US")))
        XCTAssertNil(PageEdits.number("", locale: Locale(identifier: "en_US")))
    }

    func test_aThousandsSeparatorIsRefusedAsWindowsRefusesIt() {
        XCTAssertNil(PageEdits.number("2,5", locale: Locale(identifier: "en_US")))
        XCTAssertNil(PageEdits.number("1,000", locale: Locale(identifier: "en_US")))
        XCTAssertNil(PageEdits.number("1.5", locale: Locale(identifier: "tr_TR")))
        XCTAssertNil(PageEdits.number("29.7", locale: Locale(identifier: "tr_TR")))
        XCTAssertEqual(PageEdits.number("29,7", locale: Locale(identifier: "tr_TR")), 29.7)
    }
}
