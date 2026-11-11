#if os(macOS)
import AppKit
import LazyPDFApp

// With application(_:open:) here AppKit sends the delegate every URL, files and lazypdf: addresses alike, and .onOpenURL
// never fires.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MacShell.shared.handle(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AttachmentsModel.deleteOpenedCopies(in: MacShell.shared.folders.openedAttachments)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MacShell.shared.terminateReply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MacShell.shared.showWindow() }
        return true
    }
}
#endif
