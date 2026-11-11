import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/ExitFlowTests.cs: closing the window; every document with unsaved changes is asked
// about, one after the other.

@MainActor
final class ExitFlowTests: XCTestCase {
    private func dirty(_ f: ViewModelFixture, _ name: String) async throws {
        await f.vm.open(f.pdf(name))
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, name)
        try tab.commit("Properties")
    }

    func test_withNothingUnsavedTheWindowMayClose() async {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())

        XCTAssertTrue(f.vm.requestExit())
        XCTAssertTrue(f.renderers.allSatisfy(\.disposed))
    }

    func test_theFirstDocumentWithChangesIsAskedAboutAndTheWindowStaysOpen() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf("clean.pdf"))
        try await dirty(f, "edited.pdf")

        XCTAssertFalse(f.vm.requestExit())

        XCTAssertEqual(f.vm.closeQuestion?.title, "edited.pdf")
        XCTAssertEqual(f.vm.activeDocument?.title, "edited.pdf")
    }

    func test_saveAnywayFromTheQuestionGoesOnWithTheExit() async throws {
        let f = ViewModelFixture(self)
        try await dirty(f, "one.pdf")
        let tab = f.vm.activeDocument!
        try touch(f.dir.sub("one.pdf"), Pdfs.text(3))
        f.vm.checkDisk()
        let exits = Counter()
        f.vm.exitRequested = { exits.count += 1 }
        XCTAssertFalse(f.vm.requestExit())

        XCTAssertFalse(f.vm.save(tab, closeAfter: true))
        f.vm.message?.action?.run()

        XCTAssertTrue(f.vm.documents.isEmpty)
        XCTAssertEqual(exits.count, 1)
    }

    func test_answeringEachQuestionEndsInTheExit() async throws {
        let f = ViewModelFixture(self)
        try await dirty(f, "one.pdf")
        try await dirty(f, "two.pdf")
        let exits = Counter()
        f.vm.exitRequested = { exits.count += 1 }

        XCTAssertFalse(f.vm.requestExit())
        f.vm.close(f.vm.closeQuestion!)
        XCTAssertEqual(exits.count, 0)
        XCTAssertNotNil(f.vm.closeQuestion)
        f.vm.close(f.vm.closeQuestion!)

        XCTAssertEqual(exits.count, 1)
        XCTAssertNil(f.vm.closeQuestion)
    }

    func test_cancellingTheQuestionCallsOffTheExit() async throws {
        let f = ViewModelFixture(self)
        try await dirty(f, "one.pdf")
        try await dirty(f, "two.pdf")
        let exits = Counter()
        f.vm.exitRequested = { exits.count += 1 }
        _ = f.vm.requestExit()

        f.vm.cancelClose()
        f.vm.close(f.vm.activeDocument!)

        XCTAssertEqual(exits.count, 0)
        XCTAssertEqual(f.vm.documents.count, 1)
    }
}
