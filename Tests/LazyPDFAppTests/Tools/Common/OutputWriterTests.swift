import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/optimize/OutputWriterTests.cs: where a rewritten file goes, a new tab or over the
// file on disk.

@MainActor
final class OutputWriterTests: XCTestCase {
    func test_aNewFileOpensAsAnUnsavedTabThatNeedsAName() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf("report.pdf", pages: 2))
        let tab = try XCTUnwrap(f.vm.activeDocument)

        let done = await OutputWriter.deliver(f.vm, tab, revision: tab.revision, Pdfs.text(2), replace: false, newTitle: "report (smaller).pdf")

        XCTAssertTrue(done)
        XCTAssertEqual(f.vm.documents.count, 2)
        XCTAssertEqual(f.vm.activeDocument?.title, "report (smaller).pdf")
        XCTAssertTrue(AppViewModel.needsName(try XCTUnwrap(f.vm.activeDocument)))
    }

    func test_theSameFileIsWrittenAndTheTabReadAgain() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf("report.pdf", pages: 4)
        await f.vm.open(url)
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let replacement = Pdfs.text(4)

        let done = await OutputWriter.deliver(f.vm, tab, revision: tab.revision, replacement, replace: true, newTitle: "unused.pdf")

        XCTAssertTrue(done)
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), replacement)
        XCTAssertEqual(f.vm.documents.count, 1)
        let reloaded = try XCTUnwrap(f.vm.documents.first)
        XCTAssertTrue(reloaded !== tab)
        XCTAssertEqual(reloaded.pageCount, 4)
        XCTAssertFalse(reloaded.isDirty)
    }

    func test_aDocumentWithoutAFileGoesToANewTabEvenWhenAskedToReplace() async throws {
        let f = ViewModelFixture(self)
        await f.vm.openNew(Pdfs.text(), title: "Made.pdf")
        let tab = try XCTUnwrap(f.vm.activeDocument)

        _ = await OutputWriter.deliver(f.vm, tab, revision: tab.revision, Pdfs.text(2), replace: true, newTitle: "Made (clean).pdf")

        XCTAssertEqual(f.vm.documents.count, 2)
        XCTAssertEqual(f.vm.activeDocument?.title, "Made (clean).pdf")
    }

    func test_aFileThatCannotBeWrittenIsReportedAndLeftAlone() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf("report.pdf")
        await f.vm.open(url)
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let before = try Data(contentsOf: url)

        let done = await OutputWriter.deliver(f.vm, tab, revision: tab.revision, [1, 2, 3], replace: true, newTitle: "unused.pdf")

        XCTAssertFalse(done)
        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(f.vm.activeDocument === tab)
    }

    func test_anEncryptedResultOpensWithoutAskingForThePasswordAgain() async throws {
        let f = ViewModelFixture(self)
        let url = f.locked()
        await f.vm.open(url)
        await f.vm.submitPassword("secret")
        let tab = try XCTUnwrap(f.vm.activeDocument)

        let done = await OutputWriter.deliver(f.vm, tab, revision: tab.revision, [UInt8](try Data(contentsOf: url)), replace: false,
                                              newTitle: "locked (clean).pdf")

        XCTAssertTrue(done)
        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertEqual(f.vm.activeDocument?.title, "locked (clean).pdf")
    }

    func test_aFileChangedByAnotherProgramIsNotReplaced() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf("report.pdf", pages: 1)
        await f.vm.open(url)
        let tab = try XCTUnwrap(f.vm.activeDocument)
        try touch(url, Pdfs.text(3))
        let theirs = try Data(contentsOf: url)

        XCTAssertTrue(OutputWriter.refuses(f.vm, tab, replace: true))
        let done = await OutputWriter.deliver(f.vm, tab, revision: tab.revision, Pdfs.text(4), replace: true, newTitle: "unused.pdf")

        XCTAssertFalse(done)
        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(try Data(contentsOf: url), theirs)
        XCTAssertFalse(OutputWriter.refuses(f.vm, tab, replace: false))
    }

    func test_bytesMadeBeforeAnEditAreNotDelivered() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf("report.pdf", pages: 1)
        await f.vm.open(url)
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let before = tab.revision
        try Pdfs.retitle(tab.session, "Edited")
        try tab.commit("Properties")
        let onDisk = try Data(contentsOf: url)

        let done = await OutputWriter.deliver(f.vm, tab, revision: before, Pdfs.text(2), replace: true, newTitle: "unused.pdf")

        XCTAssertFalse(done)
        XCTAssertEqual(try Data(contentsOf: url), onDisk)
        XCTAssertTrue(f.vm.activeDocument === tab)
        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_aResultWithOtherPagesIsRefusedOverTheFile() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf("report.pdf", pages: 3)
        await f.vm.open(url)
        let tab = try XCTUnwrap(f.vm.activeDocument)
        let before = try Data(contentsOf: url)

        let done = await OutputWriter.deliver(f.vm, tab, revision: tab.revision, Pdfs.text(2), replace: true, newTitle: "unused.pdf")

        XCTAssertFalse(done)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_theViewStaysWhereItWasAfterTheFileIsWritten() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf("report.pdf", pages: 4))
        let tab = try XCTUnwrap(f.vm.activeDocument)
        tab.pageIndex = 2
        tab.zoom = 1.5

        _ = await OutputWriter.deliver(f.vm, tab, revision: tab.revision, Pdfs.text(4), replace: true, newTitle: "unused.pdf")

        let reloaded = try XCTUnwrap(f.vm.activeDocument)
        XCTAssertEqual(reloaded.pageIndex, 2)
        XCTAssertEqual(reloaded.zoom, 1.5)
    }
}
