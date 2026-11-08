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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) }
        }
    }
}

/// Asks the shell before the window closes, so unsaved tabs get their question first. Everything else is left to the
/// delegate SwiftUI put there.
final class CloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let mayClose: () -> Bool

    init(original: NSWindowDelegate?, mayClose: @escaping () -> Bool) {
        self.original = original
        self.mayClose = mayClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        mayClose()
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
#endif
