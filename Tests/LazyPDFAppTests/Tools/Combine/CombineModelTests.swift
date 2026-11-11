import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The Combine panel as the window drives it. Windows has no test of the panel itself (its job is in CombineJobTests), so these
// follow its code: the list of files, the order, the ranges, the split and where the result goes. The drop of files on the panel
// is the view's: it hands the files to `add`, as the picker does.

@MainActor
final class CombineModelTests: XCTestCase {
    private func attached(_ pages: Int = 3, bytes: [UInt8]? = nil) throws -> (model: CombineModel, rig: PagesRig) {
        let rig = try PagesRig(bytes ?? Pdfs.text(pages))
        let model = CombineModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        return (model, rig)
    }

    private func add(_ model: CombineModel, _ rig: PagesRig, _ dir: TempDir, _ name: String, _ pages: Int) async {
        rig.pick(dir, name, Pdfs.text(pages, name))
        await model.addFiles()
    }

    func test_theListStartsWithTheOpenFileAndAddingFilesAppendsThem() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        XCTAssertEqual(model.entries.map(\.name), ["a.pdf"])
        XCTAssertFalse(model.action!.canRun())

        await add(model, rig, dir, "b.pdf", 2)

        XCTAssertEqual(model.entries.map(\.name), ["a.pdf", "b.pdf"])
        XCTAssertEqual(model.entries.map(\.detail), ["3 pages", "2 pages"])
        XCTAssertTrue(model.action!.canRun())
    }

    func test_eachDocumentKeepsItsOwnList() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        let other = try PagesRig(Pdfs.text(2), title: "c.pdf")

        model.detach()
        model.attach(other.tab, other.viewer, other.host)
        XCTAssertEqual(model.entries.map(\.name), ["c.pdf"])
        model.detach()
        model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertEqual(model.entries.map(\.name), ["a.pdf", "b.pdf"])
    }

    func test_theEntryOfTheOpenFileFollowsItsPages() async throws {
        let (model, rig) = try attached(3)

        try PageOperations.delete(rig.tab.document, [0])
        try rig.tab.commit("Delete pages")
        await waitUntil { model.entries[0].pages == 2 }

        XCTAssertEqual(model.entries[0].detail, "2 pages")
    }

    func test_filesMoveUpAndDownAndLeaveTheList() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        await add(model, rig, dir, "c.pdf", 2)
        let (a, b, c) = (model.entries[0], model.entries[1], model.entries[2])

        model.moveUp(a)
        XCTAssertEqual(model.entries.map(\.name), ["a.pdf", "b.pdf", "c.pdf"])
        model.moveDown(a)
        XCTAssertEqual(model.entries.map(\.name), ["b.pdf", "a.pdf", "c.pdf"])
        model.moveDown(c)
        model.move(c, onto: b)
        XCTAssertEqual(model.entries.map(\.name), ["c.pdf", "b.pdf", "a.pdf"])
        model.remove(b)
        XCTAssertEqual(model.entries.map(\.name), ["c.pdf", "a.pdf"])
    }

    func test_aFileThatCannotBeReadIsLeftOutOfTheList() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        rig.pick(dir, "bad.pdf", [1, 2, 3])

        await model.addFiles()

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Not a PDF"])
    }

    func test_combiningOpensOneNewFileOfTheListInOrder() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        model.entries[1].range = "2"

        await model.action!.run()

        XCTAssertEqual(rig.host.openedNew.map(\.title), ["Combined.pdf"])
        let made = try PdfDocument.open(rig.host.openedNew[0].pdf)
        XCTAssertEqual(made.pages.count, 4)
        XCTAssertTrue(rig.host.notices.isEmpty)
    }

    func test_aRangePastTheEndNamesTheFile() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        model.entries[1].range = "5"

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Pages not understood"])
        XCTAssertTrue(rig.host.problems[0].text.hasPrefix("b.pdf: "))
    }

    func test_theFileThatCannotBeMergedIsNamed() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        await add(model, rig, dir, "c.pdf", 2)
        model.entries[1].pages = 99
        model.entries[1].range = "99"

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Files not combined"])
        XCTAssertEqual(rig.host.problems[0].text, "b.pdf could not be put into the file. Leave it out, or try fewer of its pages.")
    }

    func test_aFileThatLimitsCopyingIsNotCombined() async throws {
        let (model, rig) = try attached(bytes: try Pdfs.restricted(.print))

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.problems.map(\.title), ["File is protected"])
    }

    func test_combiningToFilesHandsTheResultToTheExporter() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        model.toFolder = true

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.exporter.received.map(\.name), ["Combined.pdf"])
        XCTAssertEqual(rig.host.notices.map(\.title), ["1 file saved"])
        XCTAssertEqual(rig.host.notices[0].text, "/saved")
        XCTAssertNotNil(rig.host.notices[0].action)
    }

    func test_givingUpTheSaveSaysNothing() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        model.toFolder = true
        rig.host.exporter.gaveUp = true

        await model.action!.run()

        XCTAssertTrue(rig.host.notices.isEmpty)
    }

    func test_splitNeedsMoreThanOnePageAndAnAmountThatMakesSense() throws {
        let (model, _) = try attached(1)
        model.setSplitting(true)
        XCTAssertEqual(model.action?.text, "Split file")
        XCTAssertEqual(model.splitHint, "A file of one page cannot be split.")
        XCTAssertFalse(model.action!.canRun())

        let (many, _) = try attached(5)
        many.setSplitting(true)
        XCTAssertTrue(many.action!.canRun())
        many.amount = "0"
        XCTAssertFalse(many.action!.canRun())
        many.setKind(.size)
        XCTAssertEqual(many.amount, "5")
        XCTAssertEqual(many.amountLabel, "Megabytes per part")
        many.setKind(.bookmarks)
        XCTAssertFalse(many.showsAmount)
        XCTAssertTrue(many.splitHint.hasPrefix("The bookmarks make"))
    }

    func test_splittingByCountOpensThePartsAsTabs() async throws {
        let (model, rig) = try attached(5)
        model.setSplitting(true)
        model.amount = "2"

        await model.action!.run()

        XCTAssertEqual(rig.host.openedNew.map(\.title), ["a 1.pdf", "a 2.pdf", "a 3.pdf"])
        XCTAssertEqual(rig.host.statuses.last, "3 parts opened.")
        XCTAssertEqual(rig.tab.pageCount, 5)
    }

    func test_moreThanTenPartsGoToTheExporterInsteadOfTabs() async throws {
        let (model, rig) = try attached(12)
        model.setSplitting(true)
        model.amount = "1"

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.notices.first?.title, "Too many parts for tabs")
        XCTAssertEqual(rig.host.exporter.received.count, 12)
        XCTAssertEqual(rig.host.exporter.received.first?.name, "a 01.pdf")
        XCTAssertEqual(rig.host.notices.last?.title, "12 files saved")
    }

    func test_theNoticeCountsTheFilesThatWereWrittenAndAFailureIsReported() async throws {
        let (model, rig) = try attached(12)
        model.setSplitting(true)
        model.amount = "1"
        rig.host.exporter.failing = ["a 03.pdf", "a 04.pdf", "a 05.pdf"]

        await model.action!.run()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Not saved"])
        XCTAssertTrue(rig.host.problems[0].text.contains("a 03.pdf"))
        XCTAssertEqual(rig.host.notices.last?.title, "9 files saved")
    }

    func test_whenNothingIsWrittenTheFailureIsStillReported() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        model.toFolder = true
        rig.host.exporter.failing = ["Combined.pdf"]

        await model.action!.run()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Not saved"])
        XCTAssertTrue(rig.host.notices.isEmpty)
    }

    func test_aClosedTabTakesItsListWithIt() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)
        await add(model, rig, dir, "b.pdf", 2)
        let other = try PagesRig(Pdfs.text(2), title: "c.pdf")
        model.detach()
        model.attach(other.tab, other.viewer, other.host)
        XCTAssertEqual(model.heldLists, 2)

        rig.tab.dispose()
        model.detach()

        XCTAssertEqual(model.heldLists, 1)
    }

    func test_tenPartsStillOpenAsTabs() async throws {
        let (model, rig) = try attached(10)
        model.setSplitting(true)
        model.amount = "1"

        await model.action!.run()

        XCTAssertEqual(rig.host.openedNew.count, 10)
    }

    func test_aWholeFileInOnePartIsSaidAndNothingIsMade() async throws {
        let (model, rig) = try attached(3)
        model.setSplitting(true)
        model.amount = "10"

        await model.action!.run()

        XCTAssertTrue(rig.host.openedNew.isEmpty)
        XCTAssertEqual(rig.host.notices.map(\.title), ["Nothing to split"])
    }

    func test_splittingAtBookmarksNeedsOneThatStartsAfterThePageOne() async throws {
        let (model, rig) = try attached(bytes: try PagesPdfs.withBookmarksFile(4, [0]))
        model.setSplitting(true)
        model.setKind(.bookmarks)

        await model.action!.run()

        XCTAssertEqual(rig.host.problems.map(\.title), ["Nothing to cut at"])
    }

    func test_splittingAtBookmarksCutsWhereTheyPoint() async throws {
        let (model, rig) = try attached(bytes: try PagesPdfs.withBookmarksFile(5, [0, 2]))
        model.setSplitting(true)
        model.setKind(.bookmarks)

        await model.action!.run()

        XCTAssertEqual(rig.host.openedNew.count, 2)
        XCTAssertEqual(try PdfDocument.open(rig.host.openedNew[0].pdf).pages.count, 2)
    }

    func test_aFileThatLimitsCopyingIsNotSplit() async throws {
        let (model, rig) = try attached(bytes: try Pdfs.restricted(.print))
        model.setSplitting(true)

        await model.action!.run()

        XCTAssertEqual(rig.host.problems.map(\.title), ["File is protected"])
    }

    func test_theSignedNoteFollowsTheFile() throws {
        let (model, _) = try attached()
        XCTAssertFalse(model.isSigned)

        let (signed, _) = try attached(bytes: try Pdfs.signed(certified: false))

        XCTAssertTrue(signed.isSigned)
    }

    func test_aSplitBySizeSaysWhenAPartIsStillOverTheSize() async throws {
        let source = try PdfDocument.open(Pdfs.text(2))
        let noise = (0..<20_000).map { _ in UInt8.random(in: 0...255) }
        source.pages[0].dictionary["Noise"] = try source.add(PdfStream(PdfDictionary(), data: noise))
        let (model, rig) = try attached(bytes: try source.saveRewrite())
        model.setSplitting(true)
        model.setKind(.size)
        model.amount = "0.01"

        await model.action!.run()

        XCTAssertEqual(rig.host.openedNew.count, 2)
        XCTAssertEqual(rig.host.statuses.last, "2 parts opened. 1 part is bigger than 0.01 MB. A single page is too large to fit.")
    }

    func test_droppedFilesThatAreNotPdfsAreSaidToBeLeftOut() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)

        await model.drop([ToolFile(url: dir.file("b.pdf", Pdfs.text(2))), ToolFile(url: dir.file("c.txt", [65]))])

        XCTAssertEqual(model.entries.map(\.name), ["a.pdf", "b.pdf"])
        XCTAssertEqual(rig.host.notices.map(\.title), ["Not a PDF"])
        XCTAssertEqual(rig.host.notices[0].text, "1 dropped file is not a PDF and was left out.")
    }

    func test_droppedPdfsAloneSayNothing() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)

        await model.drop([ToolFile(url: dir.file("b.pdf", Pdfs.text(2)))])

        XCTAssertEqual(model.entries.count, 2)
        XCTAssertTrue(rig.host.notices.isEmpty)
    }

    func test_aDroppedPdfThatCannotBeReadGivesItsProblemAndNoNotice() async throws {
        let dir = TempDir(self)
        let (model, rig) = try attached(3)

        await model.drop([ToolFile(url: dir.file("bad.pdf", [1, 2, 3])), ToolFile(url: dir.file("c.txt", [65]))])

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(rig.host.problems.map(\.title), ["Not a PDF"])
        XCTAssertTrue(rig.host.notices.isEmpty)
    }
}
