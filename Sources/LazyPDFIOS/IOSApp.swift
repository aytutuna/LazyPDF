#if os(iOS)
import SwiftUI

/// The iPhone and iPad app. The Xcode project's app target (ios/project.yml) only starts it.
public struct IOSApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}
#endif
