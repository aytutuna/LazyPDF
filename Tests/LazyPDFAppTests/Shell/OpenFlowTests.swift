import XCTest
import Observation
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/OpenFlowTests.cs: opening from a path, a picture or a text file, what an error says,
// and what the recent list remembers. EveryChangeIsAnnouncedWithAnEmptyName is WPF's PropertyChanged; the observation of
// the strip stands in for it.

@MainActor
final class OpenFlowTests: XCTestCase {
    func test_theStripStartsWithHomeAndNothingElse() async {
        let f = ViewModelFixture(self)

        XCTAssertEqual(f.vm.strip.count, 1)
        XCTAssertTrue(f.vm.strip[0] === HomeTab.shared)
        XCTAssertTrue(f.vm.isHome)
        XCTAssertNil(f.vm.activeDocument)
    }

    func test_aClosedFileReopensAtThePageItWasLeftOn() async {
        let f = ViewModelFixture(self)
        let url = f.pdf("long.pdf", pages: 4)
        await f.vm.open(url)
        f.vm.documents[0].pageIndex = 2
        f.vm.close(f.vm.documents[0])

        await f.vm.open(url)

        XCTAssertEqual(f.vm.documents[0].pageIndex, 2)
    }

    func test_aPdfOpensInATabAndBecomesTheActiveOne() async {
        let f = ViewModelFixture(self)
        let url = f.pdf("report.pdf")

        await f.vm.open(url)

        XCTAssertEqual(f.vm.documents.count, 1)
        let tab = f.vm.documents[0]
        XCTAssertTrue(f.vm.activeTab === tab)
        XCTAssertFalse(f.vm.isHome)
        XCTAssertEqual(tab.title, "report.pdf")
        XCTAssertTrue(samePath(tab.url, url))
        XCTAssertEqual(f.vm.strip.count, 2)
        XCTAssertTrue(f.vm.strip[0] === HomeTab.shared)
        XCTAssertTrue(f.vm.strip[1] === tab)
    }

    func test_openingTheSameFileAgainShowsTheTabItAlreadyHas() async {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        await f.vm.open(f.pdf("b.pdf"))
        f.vm.select(HomeTab.shared)

        await f.vm.open(URL(fileURLWithPath: url.path.uppercased()))

        XCTAssertEqual(f.vm.documents.count, 2)
        XCTAssertEqual(f.vm.activeDocument?.title, "a.pdf")
    }

    func test_severalFilesOpenInOrderAndTheLastIsActive() async {
        let f = ViewModelFixture(self)

        await f.vm.open([f.pdf("a.pdf"), f.pdf("b.pdf"), f.pdf("c.pdf")])

        XCTAssertEqual(f.vm.documents.map(\.title), ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertEqual(f.vm.activeDocument?.title, "c.pdf")
    }

    func test_aPictureOpensAsAnUnsavedDocumentWithNoFile() async {
        let f = ViewModelFixture(self)
        let url = f.dir.file("photo.jpg", [1, 2, 3, 4])

        await f.vm.open(url)

        let tab = f.vm.activeDocument
        XCTAssertEqual(tab?.title, "photo.pdf")
        XCTAssertNil(tab?.url)
        XCTAssertEqual(tab?.isDirty, true)
        XCTAssertTrue(AppViewModel.needsName(tab!))
        XCTAssertTrue(f.vm.recent.isEmpty)
    }

    func test_aReadOnlyFileOpensWithANoticeAndSavesAsANewFile() async throws {
        try XCTSkipIf(getuid() == 0, "root can write to any file")
        let f = ViewModelFixture(self)
        let url = f.pdf("locked.pdf")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        await f.vm.open(url)

        let tab = try XCTUnwrap(f.vm.activeDocument)
        XCTAssertEqual(f.vm.message?.title, "File is read-only")
        XCTAssertTrue(tab.readOnly)
        XCTAssertTrue(AppViewModel.needsName(tab))
        XCTAssertTrue(f.vm.saveAs(tab, f.dir.sub("copy.pdf")))
        XCTAssertFalse(tab.readOnly)
        XCTAssertFalse(AppViewModel.needsName(tab))
    }

    func test_aCopyTheSystemMadeOpensWithNoFileAndSavesAsANewOne() async throws {
        let f = ViewModelFixture(self)
        let url = f.pdf("inbox.pdf")
        let before = try Data(contentsOf: url)

        await f.vm.openCopy(url, access: nil)

        let tab = try XCTUnwrap(f.vm.activeDocument)
        XCTAssertNil(tab.url)
        XCTAssertEqual(tab.title, "inbox.pdf")
        XCTAssertFalse(tab.isDirty)
        XCTAssertTrue(AppViewModel.needsName(tab))
        XCTAssertTrue(f.vm.recent.isEmpty)
        let other = f.dir.sub("other.pdf")
        XCTAssertTrue(f.vm.saveAs(tab, other))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_aTextFileOpensAsAnUnsavedDocument() async {
        let f = ViewModelFixture(self)
        let url = f.dir.file("notes.txt", Array("Some notes.".utf8))

        await f.vm.open(url)

        XCTAssertEqual(f.vm.activeDocument?.title, "notes.pdf")
        XCTAssertEqual(f.vm.activeDocument?.isDirty, true)
    }

    func test_aTextThatNeedsAFontThereIsNoneForSaysSoInWords() async {
        let f = ViewModelFixture(self)
        let url = f.dir.file("tr.txt", Array("\u{C7}al\u{131}\u{15F}ma".utf8))

        await f.vm.open(url)

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(f.vm.message?.title, "Nothing to open")
        XCTAssertEqual(f.vm.message?.isError, true)
    }

    func test_aFileThatIsNotThereIsSaidInWordsAndOpensNothing() async {
        let f = ViewModelFixture(self)

        await f.vm.open(f.dir.sub("gone.pdf"))

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(f.vm.message?.title, "File not found")
        XCTAssertTrue(f.vm.message?.text.contains("gone.pdf") == true)
    }

    func test_aFolderIsSaidToBeAFolderAndOpensNothing() async throws {
        let f = ViewModelFixture(self)
        let folder = f.dir.sub("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        await f.vm.open(folder)

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(f.vm.message?.title, "That is a folder")
    }

    func test_aFileThatIsNotAPdfIsSaidInWords() async {
        let f = ViewModelFixture(self)
        let url = f.dir.file("fake.pdf", Array("just words".utf8))

        await f.vm.open(url)

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(f.vm.message?.title, "Not a PDF")
        XCTAssertTrue(f.vm.message?.text.contains("fake.pdf") == true)
    }

    func test_aDamagedFileSaysItIsDamagedAndOffersAnEarlierCopy() async {
        let f = ViewModelFixture(self)
        let url = f.dir.file("broken.pdf", Array("%PDF-1.7\n1 0 obj\n<< /Type /Catalog".utf8))

        await f.vm.open(url)

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertTrue(f.vm.message?.text.contains("broken.pdf") == true)
    }

    func test_aDocumentTheSystemCannotDrawOpensWithANotice() async {
        let f = ViewModelFixture(self, draws: false)

        await f.vm.open(f.pdf())

        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertEqual(f.vm.message?.title, "Pages cannot be shown")
        XCTAssertEqual(f.vm.message?.isError, false)
    }

    func test_anOpenedFileIsRememberedAndAMissingOneIsForgotten() async {
        let f = ViewModelFixture(self)
        let url = f.pdf("kept.pdf")
        await f.vm.open(url)

        XCTAssertEqual(f.vm.recent.map(\.name), ["kept.pdf"])
        XCTAssertTrue(f.vm.recent[0].exists)

        try? FileManager.default.removeItem(at: url)
        await f.vm.open(f.dir.sub("kept2.pdf"))
        f.vm.close(f.vm.activeDocument!)
        XCTAssertEqual(f.vm.recent.map(\.name), ["kept.pdf"])
        XCTAssertFalse(f.vm.recent[0].exists)

        await f.vm.open(url)
        XCTAssertTrue(f.vm.recent.isEmpty)
    }

    func test_theRecentListCanBeEdited() async {
        let f = ViewModelFixture(self)
        let a = f.pdf("a.pdf")
        let b = f.pdf("b.pdf")
        await f.vm.open([a, b])

        f.vm.forgetRecent(a)
        XCTAssertEqual(f.vm.recent.map(\.name), ["b.pdf"])

        f.vm.clearRecent()
        XCTAssertTrue(f.vm.recent.isEmpty)
    }

    func test_openingIsAnnouncedToWhoeverWatchesTheStrip() async {
        let f = ViewModelFixture(self)
        let announced = Counter()
        withObservationTracking({ _ = f.vm.strip; _ = f.vm.activeTab }, onChange: { announced.count += 1 })

        await f.vm.open(f.pdf())

        XCTAssertEqual(announced.count, 1)
    }

    func test_aCopyOpenedByTheSystemWaitsForTheJobToo() async throws {
        let f = ViewModelFixture(self)
        let vm = f.vm!
        let started = Latch()
        let finish = Latch()
        let run = Task {
            try await vm.runBusy("Working") { _ in
                started.release()
                await finish.wait()
            }
        }
        await started.wait()

        await vm.openOrHold(f.pdf("inbox.pdf"), access: nil, asCopy: true)

        XCTAssertTrue(vm.documents.isEmpty)
        finish.release()
        try await run.value
        await vm.releaseHeld()
        XCTAssertEqual(vm.documents.map(\.title), ["inbox.pdf"])
        XCTAssertNil(vm.documents[0].url)
    }

    func test_aFileOpenedByTheSystemWaitsForTheJobAndThenOpens() async throws {
        let f = ViewModelFixture(self)
        let vm = f.vm!
        let started = Latch()
        let finish = Latch()
        let run = Task {
            try await vm.runBusy("Working") { _ in
                started.release()
                await finish.wait()
            }
        }
        await started.wait()
        let grant = Grant()

        await vm.openOrHold(f.pdf("late.pdf"), access: grant)

        XCTAssertTrue(vm.documents.isEmpty)
        XCTAssertEqual(vm.statusFull, "Will open when you are done here.")
        finish.release()
        try await run.value
        await vm.releaseHeld()
        XCTAssertEqual(vm.documents.map(\.title), ["late.pdf"])
        XCTAssertEqual(grant.stops, 0)
        vm.close(vm.documents[0])
        XCTAssertEqual(grant.stops, 1)
    }

    func test_aMessageShownAfterTheFileWasHeldKeepsItWaitingUntilDismissed() async {
        let f = ViewModelFixture(self)
        f.vm.showNotice("Before", "Already up.")
        f.vm.actionRunning = true
        await f.vm.openOrHold(f.pdf("a.pdf"), access: nil)
        f.vm.actionRunning = false

        await f.vm.releaseHeld()
        XCTAssertEqual(f.vm.documents.map(\.title), ["a.pdf"])

        f.vm.actionRunning = true
        await f.vm.openOrHold(f.pdf("b.pdf"), access: nil)
        f.vm.actionRunning = false
        f.vm.showNotice("After", "Came later.")

        await f.vm.releaseHeld()
        XCTAssertEqual(f.vm.documents.count, 1)
        f.vm.dismissMessage()
        await f.vm.releaseHeld()
        XCTAssertEqual(f.vm.documents.map(\.title), ["a.pdf", "b.pdf"])
    }

    func test_aFileOpensAtOnceWhileOnlyAMessageIsUp() async {
        let f = ViewModelFixture(self)
        f.vm.showNotice("Up", "Just a message.")

        await f.vm.openOrHold(f.pdf("a.pdf"), access: nil)

        XCTAssertEqual(f.vm.documents.map(\.title), ["a.pdf"])
    }
}
