#if os(macOS)
import SwiftUI

/// The Mac app. The Xcode project's app target (mac/project.yml) and Sources/LazyPDF only start it.
public struct MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        WindowGroup("Lazy PDF") {
            Color.clear
        }
    }
}
#endif
