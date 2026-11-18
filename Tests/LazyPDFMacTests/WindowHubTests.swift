#if os(macOS)
import XCTest
import AppKit
@testable import LazyPDFMac
import LazyPDFApp
import LazyPDFKit

// Not in the Windows tests: the Mac holds one shell for each window, and only one of them is the primary.

@MainActor
final class WindowHubTests: XCTestCase {
    private func file(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)-\(name)")
        try Data(MacPdfs.text()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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

    func test_quittingWithNothingUnsavedAnswersAtOnce() async throws {
        let hub = WindowHub()
        let primary = try XCTUnwrap(hub.claim(nil))
        await primary.vm.open(try file("a.pdf"))

        XCTAssertEqual(hub.terminateReply(), .terminateNow)
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
}
#endif
