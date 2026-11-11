#if os(macOS)
import XCTest
@testable import LazyPDFMac

// Not in the Windows tests: the red close button goes down the quit path instead of closing the window.

@MainActor
final class CloseGuardTests: XCTestCase {
    private final class Original: NSObject, NSWindowDelegate {
        var resized = 0

        func windowDidResize(_ notification: Notification) {
            resized += 1
        }
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }

    func test_closingAsksToQuitAndKeepsTheWindow() {
        let window = window()
        window.makeKeyAndOrderFront(nil)
        var quits = 0

        let guarded = CloseGuard.ensure(on: window, existing: nil, hasTabs: { true }) { quits += 1 }

        XCTAssertFalse(guarded.windowShouldClose(window))
        XCTAssertEqual(quits, 1)
        XCTAssertTrue(window.isVisible)
    }

    func test_closingWithNoTabsHidesTheWindowWithoutQuitting() {
        let window = window()
        window.makeKeyAndOrderFront(nil)
        var quits = 0

        let guarded = CloseGuard.ensure(on: window, existing: nil, hasTabs: { false }) { quits += 1 }

        XCTAssertFalse(guarded.windowShouldClose(window))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(quits, 0)
    }

    func test_theDelegateBeforeItStillHearsTheWindow() {
        let window = window()
        let original = Original()
        window.delegate = original

        let guarded = CloseGuard.ensure(on: window, existing: nil, hasTabs: { true }) {}
        window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification))

        XCTAssertTrue(window.delegate === guarded)
        XCTAssertEqual(original.resized, 1)
    }

    func test_theGuardStaysWhenItIsStillTheDelegate() {
        let window = window()
        let first = CloseGuard.ensure(on: window, existing: nil, hasTabs: { true }) {}

        XCTAssertTrue(CloseGuard.ensure(on: window, existing: first, hasTabs: { true }) {} === first)
    }

    func test_theGuardIsPutBackWhenAnotherDelegateTookItsPlace() {
        let window = window()
        let first = CloseGuard.ensure(on: window, existing: nil, hasTabs: { true }) {}
        let other = Original()
        window.delegate = other
        var quits = 0

        let second = CloseGuard.ensure(on: window, existing: first, hasTabs: { true }) { quits += 1 }

        XCTAssertFalse(second === first)
        XCTAssertTrue(window.delegate === second)
        XCTAssertFalse(second.windowShouldClose(window))
        XCTAssertEqual(quits, 1)
    }
}
#endif
