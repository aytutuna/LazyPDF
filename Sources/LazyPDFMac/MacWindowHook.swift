#if os(macOS)
import AppKit
import SwiftUI

/// Hands the window the view sits in to `attach` once it has one.
struct WindowHook: NSViewRepresentable {
    let attach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HookView()
        view.attach = attach
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class HookView: NSView {
        var attach: ((NSWindow) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            attach?(window)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            // SwiftUI can set its own delegate again; the guard is put back when the window next comes forward.
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.attach?(window) }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// Sends the red close button down the quit path while tabs are open, so unsaved tabs get their question first and the window
/// stays up while it is asked. With none open the window is hidden and the app stays in the Dock. Everything else is left to
/// the delegate SwiftUI put there.
final class CloseGuard: NSObject, NSWindowDelegate {
    private let original: NSWindowDelegate?
    private let hasTabs: () -> Bool
    private let quit: () -> Void

    private init(original: NSWindowDelegate?, hasTabs: @escaping () -> Bool, quit: @escaping () -> Void) {
        self.original = original
        self.hasTabs = hasTabs
        self.quit = quit
    }

    /// The guard on `window`: `existing` when it is still the delegate, a new one over whatever delegate is there otherwise.
    static func ensure(on window: NSWindow, existing: CloseGuard?, hasTabs: @escaping () -> Bool, quit: @escaping () -> Void) -> CloseGuard {
        if let existing, window.delegate === existing { return existing }
        let guarded = CloseGuard(original: window.delegate, hasTabs: hasTabs, quit: quit)
        window.delegate = guarded
        return guarded
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasTabs() { quit() } else { sender.orderOut(nil) }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
#endif
