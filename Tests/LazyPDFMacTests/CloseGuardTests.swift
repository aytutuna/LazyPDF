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
        var quits = 0

        let guarded = CloseGuard.ensure(on: window, existing: nil) { quits += 1 }

        XCTAssertFalse(guarded.windowShouldClose(window))
        XCTAssertEqual(quits, 1)
    }

    func test_theDelegateBeforeItStillHearsTheWindow() {
        let window = window()
        let original = Original()
        window.delegate = original

        let guarded = CloseGuard.ensure(on: window, existing: nil) {}
        window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification))

        XCTAssertTrue(window.delegate === guarded)
        XCTAssertEqual(original.resized, 1)
    }

    func test_theGuardStaysWhenItIsStillTheDelegate() {
        let window = window()
        let first = CloseGuard.ensure(on: window, existing: nil) {}

        XCTAssertTrue(CloseGuard.ensure(on: window, existing: first) {} === first)
    }

    func test_theGuardIsPutBackWhenAnotherDelegateTookItsPlace() {
        let window = window()
        let first = CloseGuard.ensure(on: window, existing: nil) {}
        let other = Original()
        window.delegate = other
        var quits = 0

        let second = CloseGuard.ensure(on: window, existing: first) { quits += 1 }

        XCTAssertFalse(second === first)
        XCTAssertTrue(window.delegate === second)
        XCTAssertFalse(second.windowShouldClose(window))
        XCTAssertEqual(quits, 1)
    }
}
#endif
