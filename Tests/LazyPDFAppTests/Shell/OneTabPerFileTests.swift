import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/OneTabPerFileTests.cs: a file is open in one tab only, however it is asked for: twice
// at once, by restore, or by Save as.
//
// The Windows test that gives up while the password is checked runs on a one-thread context because the app answers on
// the window's thread. Here the main actor is that thread. The test lets the submit start (the yield puts the test's
// continuation behind it in the main queue), so the check is running off the main actor when the test gives up, and
// the answer can only come back after it. Two Windows tests that hold the file open with FileShare.None are replaced by
// ones that make the read fail another way, since macOS does not lock a file.

@MainActor
final class OneTabPerFileTests: XCTestCase {
    func test_openingTheSameFileTwiceAtOnceMakesOneTab() async {
        let f = ViewModelFixture(self)
        let url = f.pdf()

        async let first: Void = f.vm.open(url)
        async let second: Void = f.vm.open(url)
        _ = await (first, second)

        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_askingForALockedFileWhileItsQuestionIsUpAddsNoSecondQuestion() async {
        let f = ViewModelFixture(self)
        let url = f.locked()
        await f.vm.open(url)

        await f.vm.open(url)
        f.vm.cancelPending()

        XCTAssertNil(f.vm.passwordRequest)
    }

    func test_sendingThePasswordTwiceAtOnceMakesOneTab() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.locked())

        async let first: Void = f.vm.submitPassword("secret")
        async let second: Void = f.vm.submitPassword("secret")
        _ = await (first, second)

        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_givingUpWhileThePasswordIsBeingCheckedOpensNothing() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.locked())

        let vm = f.vm!
        let submit = Task { await vm.submitPassword("secret") }
        await Task.yield()
        f.vm.cancelPending()
        await submit.value

        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_restoringAFileThatIsOpenBringsItBackAsACopyThatNeedsAName() async {
        let f = ViewModelFixture(self)
        let url = f.pdf("report.pdf")
        await f.vm.open(url)
        let store = RecoveryStore(directory: f.folders.recovery)
        store.write(UUID(), Pdfs.text(2), RecoveryMeta(title: "report.pdf", originalPath: url.path, saved: Date()))
        store.flush()
        f.vm.checkRecovery()

        await f.vm.restore()

        XCTAssertEqual(f.vm.documents.count, 2)
        XCTAssertEqual(f.vm.documents.filter { samePath($0.url, url) }.count, 1)
        XCTAssertTrue(AppViewModel.needsName(f.vm.activeDocument!))
    }

    func test_savingAsOntoAFileOpenInAnotherTabIsRefused() async {
        let f = ViewModelFixture(self)
        await f.vm.open([f.pdf("a.pdf"), f.pdf("b.pdf")])
        let a = f.vm.documents.first!
        let other = f.vm.documents.last!.url!

        XCTAssertFalse(f.vm.saveAs(a, other))

        XCTAssertEqual(f.vm.message?.title, "File is open")
    }

    func test_savingAsOntoItsOwnFileIsAllowed() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!

        XCTAssertTrue(f.vm.saveAs(tab, tab.url!))
    }

    func test_aFileThatIsNotThereAnyMoreLeavesTheRecentList() async {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        f.vm.close(f.vm.activeDocument!)
        try? FileManager.default.removeItem(at: url)

        await f.vm.open(url)

        XCTAssertFalse(f.vm.recent.contains { samePath($0.url, url) })
    }

    func test_aFileThatCannotBeReadStaysInTheRecentList() async {
        let f = ViewModelFixture(self)
        let url = f.pdf()
        await f.vm.open(url)
        f.vm.close(f.vm.activeDocument!)
        // A folder in its place: there, but not something to read.
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        await f.vm.open(url)

        XCTAssertTrue(f.vm.recent.contains { samePath($0.url, url) })
        XCTAssertEqual(f.vm.message?.isError, true)
    }
}
