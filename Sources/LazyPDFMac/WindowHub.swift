#if os(macOS)
import AppKit
import LazyPDFApp

// The windows of the app, as App.xaml.cs and WindowHub.cs hold them on Windows: one shell for each window, the services they
// share, the one primary window that restores the session and takes what Finder sends, and the quit that asks window by
// window.

@MainActor
final class WindowHub {
    static let shared = WindowHub()

    let registry = DocumentRegistry()
    let roster = WindowRoster()
    let toolState = TabToolState()
    let folders = DefaultAppFolders()
    let certificates = MacCertificates()
    let recovery: RecoveryStore

    private var shells: [UUID: MacShell] = [:]
    private var order: [UUID] = []
    private var openWindow: ((UUID) -> Void)?

    // The quit in progress: the windows still to be asked, what the next start reopens, and whether an answer is awaited.
    private var quitQueue: [MacShell]?
    private var quitSession: LastSession?
    private var quitAsking = false

    init() {
        recovery = RecoveryStore(directory: folders.recovery)
    }

    /// The first window. It exists before its window does, since Finder can hand over files before the scene is shown.
    func primaryShell() -> MacShell {
        let id = roster.reservePrimary()
        if let known = shells[id] { return known }
        return add(MacShell(hub: self, id: id, primary: true), first: true)
    }

    private func add(_ shell: MacShell, first: Bool = false) -> MacShell {
        shells[shell.id] = shell
        if first { order.insert(shell.id, at: 0) } else { order.append(shell.id) }
        return shell
    }

    /// The shell of the window opened with `value`; nil when the window has nothing to do and closes at once.
    func claim(_ value: UUID?) -> MacShell? {
        let (id, role) = roster.claim(value)
        switch role {
        case .closed:
            return nil
        case .primary:
            return primaryShell()
        case .secondary:
            if let known = shells[id] { return known }
            let shell = add(MacShell(hub: self, id: id, primary: false))
            if roster.arrived(id, shell.vm, registry: registry) == false {
                // The checks that held when the window was asked for failed now: the tab stays where it was.
                windowGone(shell)
                return nil
            }
            return shell
        }
    }

    /// The window of `shell` is gone. A secondary shell goes with it; the primary stays, empty, for the next time.
    func windowGone(_ shell: MacShell) {
        roster.release(shell.id)
        if shell.isPrimary { return }
        shells[shell.id] = nil
        order.removeAll { $0 == shell.id }
        registry.remove(shell.vm)
    }

    /// Kept from a live view, since `openWindow` is a SwiftUI action the delegate cannot reach.
    func captureOpenWindow(_ open: @escaping (UUID) -> Void) {
        openWindow = open
    }

    /// Opens a window for `tab` and moves it there once the window has its shell, if it still can then. The tab stays where
    /// it is when the window never appears.
    func tearOut(_ tab: DocumentTab, from shell: MacShell, at index: Int = 1) {
        guard let openWindow else { return }
        let id = roster.park(tab, from: shell.vm, at: index)
        openWindow(id)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.roster.forget(id)
        }
    }

    private var ordered: [MacShell] { order.compactMap { shells[$0] } }

    /// The window that has the keyboard, or the primary.
    var keyShell: MacShell {
        ordered.first { $0.window?.isKeyWindow == true } ?? primaryShell()
    }

    /// True when another window of the app is showing, which makes the red button of this one close it.
    func hasOtherVisibleWindow(_ shell: MacShell) -> Bool {
        shells.values.contains { $0 !== shell && $0.window?.isVisible == true }
    }

    /// Finder, the Dock and other programs.
    func handle(_ urls: [URL]) {
        primaryShell().filesFromOutside = true
        keyShell.handle(urls)
    }

    /// The Dock icon was clicked with no window showing: the primary comes back, and a new one is made when it is gone.
    func reopen(hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        let shell = primaryShell()
        if shell.window != nil {
            shell.showWindow()
            return false
        }
        guard let openWindow else { return true }
        openWindow(shell.id)
        return false
    }

    // MARK: Quit

    func terminateReply() -> NSApplication.TerminateReply {
        // Answering a question closes tabs one by one, so what the next start reopens is taken before it starts.
        if quitQueue == nil {
            quitQueue = ordered
            quitSession = registry.session()
        }
        return askNext()
    }

    // Every window is asked before any of them lets go of its tabs, so a Cancel in the last one leaves the others open.
    private func askNext() -> NSApplication.TerminateReply {
        while let shell = quitQueue?.first {
            if shell.vm.requestExit(dispose: false) {
                quitQueue?.removeFirst()
                continue
            }
            // A job that is still running answers with a notice and no question; quitting waits for another try.
            if shell.vm.closeQuestion == nil {
                endQuit()
                return .terminateCancel
            }
            quitAsking = true
            shell.showWindow()
            return .terminateLater
        }
        if let session = quitSession { primaryShell().vm.keep(session) }
        for shell in ordered { shell.vm.closeAllTabs() }
        endQuit()
        return .terminateNow
    }

    private func endQuit() {
        quitQueue = nil
        quitSession = nil
        quitAsking = false
    }

    /// A window ran out of tabs to ask about: the quit goes on to the next one, a close of that window completes, and
    /// anything else starts a quit.
    func exitFinished(_ shell: MacShell) {
        if quitAsking, quitQueue?.first === shell {
            quitQueue?.removeFirst()
            quitAsking = false
            switch askNext() {
            case .terminateNow: NSApp.reply(toApplicationShouldTerminate: true)
            case .terminateCancel: NSApp.reply(toApplicationShouldTerminate: false)
            default: break
            }
        } else if shell.closing {
            shell.closing = false
            shell.window?.close()
        } else {
            NSApp.terminate(nil)
        }
    }

    /// The close question of a window went away without the window finishing: it was answered with Cancel.
    func closeQuestionChanged(_ shell: MacShell) {
        if shell.vm.closeQuestion != nil { return }
        if quitAsking, quitQueue?.first === shell {
            endQuit()
            NSApp.reply(toApplicationShouldTerminate: false)
        }
        shell.closing = false
    }
}
#endif
