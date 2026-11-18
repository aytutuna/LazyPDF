#if os(macOS)
import AppKit
import LazyPDFApp
import LazyPDFKit
import LazyPDFUI

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
    // Where a window made for a tab goes, by its id; and the strip a drag was let go on, until its source has seen the end.
    private var placements: [UUID: CGPoint] = [:]
    private var dropped: (shell: MacShell, index: Int)?

    // The quit in progress: the windows still to be asked, what the next start reopens, and whether an answer is awaited.
    private var quitQueue: [MacShell]?
    private var quitSession: LastSession?
    private var quitAsking = false
    private var quitRechecked = false

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
            shell.placeAt = placements.removeValue(forKey: id)
            switch roster.arrived(id, shell.vm, registry: registry) {
            case false?:
                // The checks that held when the window was asked for failed now: the tab stays where it was.
                windowGone(shell)
                return nil
            case true?:
                shell.vm.setStatus(L10n.t("Moved {0} to a new window.", shell.vm.activeDocument?.title ?? ""))
                closeEmptied()
            case nil:
                break
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
        shell.teardown()
    }

    /// Asks the scene for a window for a shell whose own has gone.
    func reopenWindow(of shell: MacShell) {
        openWindow?(shell.id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Kept from a live view, since `openWindow` is a SwiftUI action the delegate cannot reach.
    func captureOpenWindow(_ open: @escaping (UUID) -> Void) {
        openWindow = open
    }

    /// Opens a window for `tab` and moves it there once the window has its shell, if it still can then. The tab stays where
    /// it is when the window never appears.
    func tearOut(_ tab: DocumentTab, from shell: MacShell, at index: Int = 1, near point: CGPoint? = nil) {
        guard let openWindow else { return }
        let id = roster.park(tab, from: shell.vm, at: index)
        placements[id] = point
        openWindow(id)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.roster.forget(id)
            self.placements[id] = nil
        }
    }

    /// The menu route: checks first, so a refused move opens no window, then a window for the tab.
    func moveToNewWindow(_ tab: DocumentTab, from shell: MacShell, near point: CGPoint? = nil) {
        guard shell.vm.mayRelease(tab) else { return }
        tearOut(tab, from: shell, near: point)
    }

    /// A tab was dropped on the strip of `shell`. A tab of the same window is reordered at once; one from another window is
    /// only noted, since this runs inside the source's drag session: the source moves it when the session has ended, with
    /// its checks and any notice outside the drag.
    func drop(_ id: UUID, on shell: MacShell, at index: Int) -> Bool {
        guard let owner = registry.find(id), let tab = owner.documents.first(where: { $0.id == id }) else { return false }
        if owner === shell.vm {
            shell.vm.moveTab(tab, to: index)
        } else {
            dropped = (shell, index)
        }
        return true
    }

    /// A drag that began on the strip of `shell` is over: the tab goes to the strip it was dropped on, or to a window of its
    /// own when nobody took it and it was let go far from the strip.
    func dragEnded(_ tab: DocumentTab, from shell: MacShell, _ end: TabDragEnd) {
        let target = dropped
        dropped = nil
        if !shell.vm.documents.contains(where: { $0 === tab }) { return }
        if let target, target.shell !== shell, shells[target.shell.id] != nil {
            move(tab, from: shell, to: target.shell, at: target.index)
        } else if TabDrag.tearsOut(taken: end.taken, escaped: end.escaped, at: end.screen, strip: end.strip) {
            moveToNewWindow(tab, from: shell, near: end.screen)
        }
    }

    /// Moves `tab` to another window, at the end of its strip unless told otherwise.
    func move(_ tab: DocumentTab, from shell: MacShell, to target: MacShell, at index: Int = Int.max) {
        guard shell.vm.mayRelease(tab),
              registry.transfer(tab, from: shell.vm, to: target.vm, at: index, targetFree: target.isFree) else { return }
        target.vm.setStatus(L10n.t("Moved {0} to another window.", tab.title))
        target.showWindow()
        closeEmptied()
    }

    /// The windows `shell` can send a tab to, numbered as the Window menu lists them.
    func targets(besides shell: MacShell) -> [TabMoveTarget] {
        let showing = ordered.filter { $0.window?.isVisible == true || $0.window?.isMiniaturized == true }
        return showing.enumerated().compactMap { number, target in
            guard target !== shell else { return nil }
            let name = L10n.t("Window {0}: {1}", String(number + 1), target.window?.title ?? "Lazy PDF")
            return TabMoveTarget(id: target.id, name: name, move: { [unowned self, unowned shell, unowned target] tab in
                self.move(tab, from: shell, to: target)
            })
        }
    }

    // A window made for a tab goes when the tab leaves it, unless something is still being opened or asked there.
    private func closeEmptied() {
        for shell in ordered where !shell.isPrimary && shell.window != nil && shell.vm.documents.isEmpty
            && !shell.vm.isOpening && !shell.vm.isBlocked {
            shell.closeWindow()
        }
    }

    private var ordered: [MacShell] { order.compactMap { shells[$0] } }

    /// The window the person is working in, or the primary. A sheet or panel on top of a window counts as that window.
    var keyShell: MacShell {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            guard let window = candidate else { continue }
            let root = window.sheetParent ?? window
            if let found = ordered.first(where: { $0.window === root }) { return found }
        }
        return primaryShell()
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
        while true {
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
                quitRechecked = false
                shell.showWindow()
                return .terminateLater
            }
            // The other windows stay usable while a question is up, so each is asked once more after the last answer.
            if quitRechecked { break }
            quitRechecked = true
            quitQueue = ordered
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
        quitRechecked = false
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
            shell.closeWindow()
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
