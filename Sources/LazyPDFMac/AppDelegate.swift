#if os(macOS)
import AppKit
import LazyPDFApp

// With application(_:open:) here AppKit sends the delegate every URL, files and lazypdf: addresses alike, and .onOpenURL
// never fires.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Once for the app, before any window: a window made later must not remove the copies another one has open in other
    // programs, or the work folder of an export that is running.
    func applicationWillFinishLaunching(_ notification: Notification) {
        AttachmentsModel.deleteOpenedCopies(in: DefaultAppFolders().openedAttachments)
        Exporter.deleteLeftovers()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WindowHub.shared.handle(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AttachmentsModel.deleteOpenedCopies(in: DefaultAppFolders().openedAttachments)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowHub.shared.terminateReply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowHub.shared.reopen(hasVisibleWindows: flag)
    }
}
#endif
