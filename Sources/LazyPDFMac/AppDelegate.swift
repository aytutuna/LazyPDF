#if os(macOS)
import AppKit

// There is no application(_:open:): once the delegate implements it AppKit sends it every URL and .onOpenURL never fires.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
