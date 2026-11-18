import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows the Release, Adopt and Transfer tests of windows/LazyPDF.App.Tests: a tab moves between two view models of one
// registry as the object it is, is refused while either window is busy, and goes back where it came from when the move fails.

@MainActor
final class TabMoveTests: XCTestCase {
    @MainActor
    private struct Windows {
        let f: ViewModelFixture
        let registry = DocumentRegistry()
        let state = TabToolState()
        let a: AppViewModel
        let b: AppViewModel

        init(_ test: XCTestCase) {
            f = ViewModelFixture(test)
            a = f.makeViewModel(registry: registry, toolState: state)
            b = f.makeViewModel(registry: registry, toolState: state)
        }

        func dirty(_ name: String = "a.pdf") async throws -> DocumentTab {
            await a.open(f.pdf(name))
            let tab = a.activeDocument!
            try Pdfs.retitle(tab.session, "Changed")
            try tab.commit("Properties")
            return tab
        }

        @discardableResult
        func move(_ tab: DocumentTab, at index: Int = 1, targetFree: Bool = true) -> Bool {
            registry.transfer(tab, from: a, to: b, at: index, targetFree: targetFree)
        }

        func assertStays(_ tab: DocumentTab, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(a.documents.contains { $0 === tab }, file: file, line: line)
            XCTAssertTrue(b.documents.isEmpty, file: file, line: line)
            XCTAssertEqual(a.message?.title, "Tab not moved", file: file, line: line)
        }
    }

    func test_theTabMovesAsTheSameObjectWithItsHistory() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        let id = tab.id

        XCTAssertTrue(w.move(tab))

        XCTAssertTrue(w.a.documents.isEmpty)
        XCTAssertTrue(w.a.isHome)
        XCTAssertTrue(w.b.documents.first === tab)
        XCTAssertTrue(w.b.activeTab === tab)
        XCTAssertEqual(tab.id, id)
        XCTAssertEqual(tab.session.undoLabel, "Properties")
        XCTAssertFalse(w.f.renderers[0].disposed)
        w.b.undo()
        XCTAssertFalse(tab.isDirty)
        XCTAssertFalse(w.b.canUndo)
    }

    func test_theRecoveryCopyOfAMovedTabStays() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        w.a.recovery.flush()
        XCTAssertEqual(w.a.recovery.list().count, 1)

        XCTAssertTrue(w.move(tab))
        w.a.recovery.flush()

        XCTAssertEqual(w.a.recovery.list().map(\.id), [tab.id])
    }

    func test_theSourceFallsBackToANeighbour() async throws {
        let w = Windows(self)
        await w.a.open([w.f.pdf("x.pdf"), w.f.pdf("y.pdf")])
        let y = w.a.documents[1]
        let x = w.a.documents[0]

        XCTAssertTrue(w.move(y))
        XCTAssertTrue(w.a.activeTab === x)
        XCTAssertTrue(w.a.lastDocument === x)

        XCTAssertTrue(w.registry.transfer(x, from: w.a, to: w.b, at: 1))
        XCTAssertTrue(w.a.isHome)
        XCTAssertNil(w.a.lastDocument)
        XCTAssertEqual(w.b.documents.map(\.title), ["x.pdf", "y.pdf"])
    }

    func test_aChangeAfterTheMoveReachesTheTargetOnly() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        XCTAssertTrue(w.move(tab))
        let before = (w.a.version, w.b.version)

        try Pdfs.retitle(tab.session, "Again")
        try tab.commit("Properties")

        XCTAssertEqual(w.a.version, before.0)
        XCTAssertGreaterThan(w.b.version, before.1)
    }

    func test_homeCannotLeave() async {
        let w = Windows(self)

        XCTAssertFalse(w.a.canRelease(HomeTab.shared))
        XCTAssertEqual(w.a.releaseRefusal(HomeTab.shared), "The Home tab stays where it is.")
    }

    func test_aBusySourceRefusesAndSaysWhy() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        w.a.actionRunning = true

        XCTAssertFalse(w.move(tab))

        w.assertStays(tab)
        XCTAssertEqual(w.a.message?.text, "Wait for the job to end, or cancel it, then move the tab.")
    }

    func test_aTabWithAQuestionAboutItStays() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        XCTAssertFalse(w.a.requestClose(tab))

        XCTAssertFalse(w.move(tab))

        XCTAssertTrue(w.a.closeQuestion === tab)
        XCTAssertTrue(w.a.documents.contains { $0 === tab })
        XCTAssertTrue(w.b.documents.isEmpty)
    }

    func test_aTabBeingReloadedStays() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        w.a.reloading.insert(ObjectIdentifier(tab))

        XCTAssertFalse(w.move(tab))

        w.assertStays(tab)
    }

    func test_aTabQueuedByAnExitStays() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        w.a.exiting = true

        XCTAssertFalse(w.move(tab))

        w.assertStays(tab)
    }

    func test_aTabWhoseComparisonIsOpenStays() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        let held = HeldComparison(session, file: nil, openIsNew: true, revision: 0)
        held.window = CompareWindowModel(session, session.rows(.all), { FakeRenderer() })
        w.a.toolState.compare[tab] = held

        XCTAssertFalse(w.move(tab))

        w.assertStays(tab)
        XCTAssertEqual(w.a.message?.text, "Close the comparison first.")
    }

    func test_aBusyTargetRefusesAndTheSourceKeepsTheTab() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        let ways: [() -> Void] = [
            { w.b.actionRunning = true },
            { w.b.actionRunning = false; w.b.exiting = true },
            { w.b.exiting = false; w.b.sheetOpen = true },
        ]
        for way in ways {
            way()
            XCTAssertFalse(w.move(tab))
            XCTAssertTrue(w.a.documents.first === tab)
            XCTAssertTrue(w.b.documents.isEmpty)
        }
        w.b.sheetOpen = false

        XCTAssertFalse(w.move(tab, targetFree: false))
        XCTAssertTrue(w.a.documents.first === tab)
    }

    func test_aTargetWithAPasswordPromptOrAQuestionRefuses() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        await w.b.open(w.f.locked())
        XCTAssertNotNil(w.b.passwordRequest)

        XCTAssertFalse(w.move(tab))
        XCTAssertTrue(w.a.documents.first === tab)

        w.b.cancelPending()
        w.b.closeQuestion = tab
        XCTAssertFalse(w.move(tab))
        XCTAssertTrue(w.a.documents.first === tab)
        XCTAssertTrue(w.b.documents.isEmpty)
    }

    func test_typedTextInTheTargetRefusesTheMove() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        w.b.handInOnSwitch = { false }

        XCTAssertFalse(w.move(tab))

        w.assertStays(tab)
    }

    func test_typedTextForTheMovedTabIsHandedInFirst() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        let asked = Counter()
        w.a.handInTyping = {
            asked.count += 1
            return true
        }

        XCTAssertTrue(w.move(tab))
        XCTAssertEqual(asked.count, 1)
    }

    func test_typedTextThatWaitsForAnAnswerKeepsTheTabHere() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        w.a.handInTyping = { false }

        XCTAssertFalse(w.move(tab))

        XCTAssertTrue(w.a.documents.first === tab)
        XCTAssertTrue(w.b.documents.isEmpty)
    }

    func test_waitingMarksAndMeasurementsTravelAndDoNotBlock() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        tab.pendingMarks = 2
        tab.pendingMeasurements = 1

        XCTAssertTrue(w.move(tab))
        XCTAssertFalse(w.b.requestClose(tab))

        XCTAssertTrue(w.b.closeQuestion === tab)
        XCTAssertEqual(tab.pendingMarks, 2)
    }

    func test_aFailedAdoptPutsTheTabBackAtItsPlace() async throws {
        let w = Windows(self)
        await w.a.open([w.f.pdf("x.pdf"), w.f.pdf("y.pdf"), w.f.pdf("z.pdf")])
        let y = w.a.documents[1]
        // A shell that fails while letting go of the tab: the target then cannot take it.
        w.a.released = { $0.dispose() }

        XCTAssertFalse(w.move(y))

        XCTAssertEqual(w.a.documents.map(\.title), ["x.pdf", "y.pdf", "z.pdf"])
        XCTAssertTrue(w.b.documents.isEmpty)
        XCTAssertEqual(w.a.message?.title, "Tab not moved")
        XCTAssertEqual(w.registry.models.filter { $0.documents.contains { $0 === y } }.count, 1)
    }

    func test_aNoticeAboutTheMovedTabStaysBehindNoMore() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        w.a.showNotice("File is read-only", "a.pdf is read-only.")
        XCTAssertTrue(w.a.messageTab === tab)

        XCTAssertTrue(w.move(tab))

        XCTAssertNil(w.a.message)
    }

    func test_aButtonOnTheInfoBarCannotActOnATabThatLeft() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()
        w.a.showNotice("File changed", "a.pdf was changed.", NoticeAction("Open that version") {})

        XCTAssertTrue(w.move(tab))

        XCTAssertNil(w.a.message)
    }

    func test_aDropOnEmptySpaceLandsLast() async throws {
        let w = Windows(self)
        await w.b.open([w.f.pdf("p.pdf"), w.f.pdf("q.pdf")])
        let tab = try await w.dirty()

        XCTAssertTrue(w.move(tab, at: w.b.strip.count))

        XCTAssertEqual(w.b.documents.map(\.title), ["p.pdf", "q.pdf", "a.pdf"])
    }

    func test_aMoveNeverGoesBeforeHome() async throws {
        let w = Windows(self)
        let tab = try await w.dirty()

        XCTAssertTrue(w.move(tab, at: 0))

        XCTAssertTrue(w.b.strip.first is HomeTab)
    }

    func test_aPasswordOpenedFileStaysOpenAndDrawn() async throws {
        let w = Windows(self)
        await w.a.open(w.f.locked())
        await w.a.submitPassword("secret")
        let tab = try XCTUnwrap(w.a.activeDocument)
        let loads = w.f.renderers.last!.loads

        XCTAssertTrue(w.move(tab))

        XCTAssertEqual(tab.password, "secret")
        XCTAssertTrue(tab.canDraw)
        XCTAssertEqual(w.f.renderers.last!.loads, loads)
        XCTAssertNil(w.b.passwordRequest)
    }

    func test_aMadeDocumentStaysUnsavedWithItsRecoveryCopy() async throws {
        let w = Windows(self)
        await w.a.openNew(Pdfs.text(), title: "Scan.pdf")
        let tab = try XCTUnwrap(w.a.activeDocument)
        w.a.recovery.flush()

        XCTAssertTrue(w.move(tab))
        w.a.recovery.flush()

        XCTAssertTrue(AppViewModel.needsName(tab))
        XCTAssertEqual(w.a.recovery.list().map(\.id), [tab.id])
    }

    func test_theFileCanStillBeSavedAfterTheMove() async throws {
        let w = Windows(self)
        let grant = Grant()
        await w.a.open(w.f.pdf("save.pdf"), access: grant)
        let tab = try XCTUnwrap(w.a.activeDocument)
        try Pdfs.retitle(tab.session, "Changed")
        try tab.commit("Properties")

        XCTAssertTrue(w.move(tab))

        XCTAssertEqual(grant.stops, 0)
        XCTAssertTrue(w.b.save(tab))
        XCTAssertFalse(tab.isDirty)
    }

    func test_aFileOpenInOneWindowIsBroughtForwardFromTheOther() async throws {
        let w = Windows(self)
        let url = w.f.pdf("one.pdf")
        await w.a.open(url)
        let tab = try XCTUnwrap(w.a.activeDocument)
        var forwarded: [DocumentTab] = []
        w.a.bringForward = { forwarded.append($0) }

        await w.b.open(url)

        XCTAssertTrue(w.b.documents.isEmpty)
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertTrue(forwarded.first === tab)
    }

    func test_theSameFileAskedForInTwoWindowsAtOnceMakesOneTab() async throws {
        let w = Windows(self)
        let url = w.f.pdf("both.pdf")

        async let first: Void = w.a.open(url)
        async let second: Void = w.b.open(url)
        _ = await (first, second)

        XCTAssertEqual(w.a.documents.count + w.b.documents.count, 1)
    }

    func test_aMovedFileIsStillFoundByItsPath() async throws {
        let w = Windows(self)
        let url = w.f.pdf("moved.pdf")
        await w.a.open(url)
        let tab = try XCTUnwrap(w.a.activeDocument)
        XCTAssertTrue(w.move(tab))
        var forwarded = 0
        w.b.bringForward = { _ in forwarded += 1 }

        await w.a.open(url)

        XCTAssertTrue(w.a.documents.isEmpty)
        XCTAssertEqual(forwarded, 1)
        XCTAssertTrue(w.registry.find(tab.id) === w.b)
    }

    func test_theSessionListsEveryWindowsFilesWithTheFirstWindowsFirst() async throws {
        let w = Windows(self)
        await w.a.open(w.f.pdf("one.pdf"))
        await w.b.open(w.f.pdf("two.pdf"))

        let session = w.registry.session()

        XCTAssertEqual(session.files.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["one.pdf", "two.pdf"])
        XCTAssertEqual(session.active, 0)
    }
}
