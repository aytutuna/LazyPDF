#if os(macOS)
import XCTest
import AppKit
import Observation
@testable import LazyPDFMac
import LazyPDFApp
import LazyPDFKit
import LazyPDFUI

// Not in the Windows tests: the Mac holds one shell for each window, and only one of them is the primary.

private final class ChangeCount: @unchecked Sendable {
    var count = 0
}

@MainActor
final class WindowHubTests: XCTestCase {
    private func file(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)-\(name)")
        try Data(MacPdfs.text()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func edit(_ tab: DocumentTab, _ title: String) throws {
        var metadata = DocumentMetadata.read(tab.session.document)
        metadata.title = title
        try metadata.write(tab.session.document)
        try tab.commit("Properties")
    }

    func test_theFirstWindowGetsThePrimaryShellFilesMayHaveReachedAlready() {
        let hub = WindowHub()
        let early = hub.primaryShell()

        let first = hub.claim(nil)

        XCTAssertTrue(first === early)
        XCTAssertTrue(early.isPrimary)
        XCTAssertTrue(early.vm.offersRecovery)
    }

    func test_aSecondWindowWithNoValueOrAnUnknownOneClosesItself() {
        let hub = WindowHub()
        _ = hub.claim(nil)

        XCTAssertNil(hub.claim(nil))
        XCTAssertNil(hub.claim(UUID()))
    }

    func test_aWindowOpenedForATabIsASecondaryThatTakesIt() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open(try file("a.pdf"))
        let tab = try XCTUnwrap(primary.vm.activeDocument)
        let id = hub.roster.park(tab, from: primary.vm, at: 1)

        let second = try XCTUnwrap(hub.claim(id))

        XCTAssertFalse(second.isPrimary)
        XCTAssertFalse(second.vm.offersRecovery)
        XCTAssertTrue(second.vm.documents.first === tab)
        XCTAssertTrue(primary.vm.documents.isEmpty)
        XCTAssertTrue(hub.registry.find(tab.id) === second.vm)
    }

    func test_aMoveThatIsRefusedByNowLeavesTheTabAndClosesTheNewWindow() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open(try file("a.pdf"))
        let tab = try XCTUnwrap(primary.vm.activeDocument)
        let id = hub.roster.park(tab, from: primary.vm, at: 1)
        primary.vm.actionRunning = true

        XCTAssertNil(hub.claim(id))

        XCTAssertTrue(primary.vm.documents.first === tab)
        XCTAssertEqual(hub.registry.models.count, 1)
    }

    func test_aSecondaryShellGoesWithItsWindowAndThePrimaryStays() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open(try file("a.pdf"))
        let id = hub.roster.park(try XCTUnwrap(primary.vm.activeDocument), from: primary.vm, at: 1)
        let second = try XCTUnwrap(hub.claim(id))

        hub.windowGone(second)
        hub.windowGone(primary)

        XCTAssertEqual(hub.registry.models.count, 1)
        XCTAssertTrue(hub.primaryShell() === primary)
        XCTAssertTrue(hub.claim(nil) === primary)
    }

    func test_theRedButtonOfThePrimaryEmptiesItAndLeavesItReadyForTheSameFile() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        let url = try file("a.pdf")
        await primary.vm.open([url, try file("b.pdf")])
        let id = hub.roster.park(primary.vm.documents[1], from: primary.vm, at: 1)
        let second = try XCTUnwrap(hub.claim(id))
        let primaryWindow = NSWindow()
        let secondWindow = NSWindow()
        primary.attach(primaryWindow)
        second.attach(secondWindow)
        secondWindow.orderFront(nil)

        let closes = try XCTUnwrap(primaryWindow.delegate).windowShouldClose?(primaryWindow)

        XCTAssertEqual(closes, false)
        XCTAssertTrue(primary.vm.documents.isEmpty)
        await second.vm.open(url)
        XCTAssertNotNil(second.vm.tab(of: url))
        XCTAssertEqual(second.vm.documents.count, 2)
    }

    func test_quittingWithNothingUnsavedAnswersAtOnce() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open(try file("a.pdf"))

        XCTAssertEqual(hub.terminateReply(), .terminateNow)
    }

    func test_aWindowEditedWhileAnotherIsBeingAskedIsAskedToo() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open([try file("a.pdf"), try file("b.pdf")])
        let id = hub.roster.park(primary.vm.documents[1], from: primary.vm, at: 1)
        let second = try XCTUnwrap(hub.claim(id))
        let late = try XCTUnwrap(primary.vm.activeDocument)
        let asked = try XCTUnwrap(second.vm.activeDocument)
        try edit(asked, "Changed")

        XCTAssertEqual(hub.terminateReply(), .terminateLater)
        try edit(late, "Edited")
        second.vm.close(asked)

        XCTAssertTrue(primary.vm.closeQuestion === late)
        XCTAssertFalse(late.isDisposed)
    }

    func test_quittingAsksWindowByWindowAndACancelKeepsEveryTab() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open([try file("a.pdf"), try file("b.pdf")])
        let id = hub.roster.park(primary.vm.documents[1], from: primary.vm, at: 1)
        let second = try XCTUnwrap(hub.claim(id))
        let tab = try XCTUnwrap(second.vm.activeDocument)
        var metadata = DocumentMetadata.read(tab.session.document)
        metadata.title = "Changed"
        try metadata.write(tab.session.document)
        try tab.commit("Properties")

        XCTAssertEqual(hub.terminateReply(), .terminateLater)
        XCTAssertTrue(second.vm.closeQuestion === tab)
        second.vm.cancelClose()

        XCTAssertEqual(primary.vm.documents.count, 1)
        XCTAssertFalse(primary.vm.documents[0].isDisposed)
        XCTAssertEqual(second.vm.documents.count, 1)
    }

    func test_moveToWindowKeepsTheTabAndSaysSoInTheTarget() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open([try file("a.pdf"), try file("b.pdf")])
        let id = hub.roster.park(primary.vm.documents[1], from: primary.vm, at: 1)
        let second = try XCTUnwrap(hub.claim(id))
        let tab = try XCTUnwrap(primary.vm.documents.first)

        hub.move(tab, from: primary, to: second)

        XCTAssertTrue(primary.vm.documents.isEmpty)
        XCTAssertTrue(second.vm.documents.last === tab)
        XCTAssertEqual(second.vm.statusFull, "Moved \(tab.title) to another window.")
        XCTAssertTrue(hub.registry.find(tab.id) === second.vm)
    }

    func test_aRefusedMoveSaysWhyInTheSourceAndKeepsTheTab() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open([try file("a.pdf"), try file("b.pdf")])
        let id = hub.roster.park(primary.vm.documents[1], from: primary.vm, at: 1)
        let second = try XCTUnwrap(hub.claim(id))
        let tab = try XCTUnwrap(primary.vm.documents.first)
        primary.vm.actionRunning = true

        hub.move(tab, from: primary, to: second)

        XCTAssertTrue(primary.vm.documents.first === tab)
        XCTAssertEqual(primary.vm.message?.title, "Tab not moved")
        XCTAssertEqual(second.vm.documents.count, 1)
    }

    func test_aTabAsksItsChecksBeforeAWindowIsMadeForIt() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open(try file("a.pdf"))
        let tab = try XCTUnwrap(primary.vm.activeDocument)
        primary.vm.actionRunning = true

        hub.moveToNewWindow(tab, from: primary)

        XCTAssertEqual(primary.vm.message?.title, "Tab not moved")
        XCTAssertTrue(primary.vm.documents.first === tab)
    }

    private func twoWindows(_ hub: WindowHub) async throws -> (first: MacShell, second: MacShell) {
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open([try file("a.pdf"), try file("b.pdf"), try file("c.pdf")])
        let id = hub.roster.park(primary.vm.documents[2], from: primary.vm, at: 1)
        return (primary, try XCTUnwrap(hub.claim(id)))
    }

    private let taken = TabDragEnd(screen: .zero, strip: .zero, taken: true, escaped: false)

    func test_aTabDroppedOnAnotherStripMovesOnlyWhenItsDragHasEnded() async throws {
        let hub = WindowHub()
        let (first, second) = try await twoWindows(hub)
        let tab = first.vm.documents[0]

        XCTAssertTrue(hub.drop(tab.id, on: second, at: 1))
        XCTAssertTrue(first.vm.documents.contains { $0 === tab })

        hub.dragEnded(tab, from: first, taken)

        XCTAssertFalse(first.vm.documents.contains { $0 === tab })
        XCTAssertTrue(second.vm.documents.first === tab)
        XCTAssertEqual(second.vm.statusFull, "Moved \(tab.title) to another window.")
    }

    func test_aTabDroppedOnItsOwnStripIsReorderedAtOnce() async throws {
        let hub = WindowHub()
        let (first, _) = try await twoWindows(hub)
        let tab = first.vm.documents[1]

        XCTAssertTrue(hub.drop(tab.id, on: first, at: 1))

        XCTAssertTrue(first.vm.documents.first === tab)
    }

    func test_anIdNoWindowOwnsIsRefused() async throws {
        let hub = WindowHub()
        let (_, second) = try await twoWindows(hub)

        XCTAssertFalse(hub.drop(UUID(), on: second, at: 1))
    }

    func test_theNoteOfADropIsUsedOnceAndAnEscapedDragMovesNothing() async throws {
        let hub = WindowHub()
        let (first, second) = try await twoWindows(hub)
        let tab = first.vm.documents[0]
        XCTAssertTrue(hub.drop(tab.id, on: second, at: 1))
        hub.dragEnded(tab, from: first, taken)
        let other = first.vm.documents[0]
        let far = TabDragEnd(screen: CGPoint(x: 0, y: 900), strip: CGRect(x: 0, y: 0, width: 800, height: 30), taken: false, escaped: true)

        hub.dragEnded(other, from: first, taken)
        hub.dragEnded(other, from: first, far)

        XCTAssertTrue(first.vm.documents.contains { $0 === other })
    }

    func test_onlyADragNobodyTookAndLetGoFarFromTheStripOpensAWindow() async throws {
        let hub = WindowHub()
        let (first, _) = try await twoWindows(hub)
        var opened = 0
        hub.captureOpenWindow { _ in opened += 1 }
        let strip = CGRect(x: 0, y: 0, width: 800, height: 30)
        let escaped = TabDragEnd(screen: CGPoint(x: 0, y: 900), strip: strip, taken: false, escaped: true)
        let far = TabDragEnd(screen: CGPoint(x: 0, y: 900), strip: strip, taken: false, escaped: false)

        hub.dragEnded(first.vm.documents[0], from: first, taken)
        hub.dragEnded(first.vm.documents[0], from: first, escaped)
        XCTAssertEqual(opened, 0)

        hub.dragEnded(first.vm.documents[0], from: first, far)
        XCTAssertEqual(opened, 1)
    }

    func test_theListOfWindowsIsRedrawnWhenOneComesOrGoes() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open(try file("a.pdf"))
        let changes = ChangeCount()
        func watch() {
            withObservationTracking({ _ = hub.targets(besides: primary) }, onChange: { changes.count += 1 })
        }

        watch()
        let id = hub.roster.park(try XCTUnwrap(primary.vm.activeDocument), from: primary.vm, at: 1)
        let second = try XCTUnwrap(hub.claim(id))
        XCTAssertEqual(changes.count, 1)

        watch()
        hub.windowGone(second)
        XCTAssertEqual(changes.count, 2)
    }

    func test_anEmptiedWindowThatWaitedForASheetClosesWhenTheWindowEndsIt() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open([try file("a.pdf"), try file("b.pdf")])
        let id = hub.roster.park(primary.vm.documents[1], from: primary.vm, at: 1)
        let second = try XCTUnwrap(hub.claim(id))
        let window = NSWindow()
        second.attach(window)
        second.vm.sheetOpen = true
        second.vm.close(try XCTUnwrap(second.vm.activeDocument))
        hub.closeEmpty(second)
        XCTAssertTrue(second.closeWhenIdle)

        second.vm.sheetOpen = false
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        for _ in 0..<50 where second.closeWhenIdle { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertFalse(second.closeWhenIdle)
    }
}
#endif
