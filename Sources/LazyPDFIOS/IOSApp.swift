#if os(iOS)
import SwiftUI

/// The iPhone and iPad app. The Xcode project's app target (ios/project.yml) only starts it. One scene: Info.plist turns
/// multiple scenes off, so a second window would need a model of its own per scene.
public struct IOSApp: App {
    @State private var shell: IOSShell

    public init() {
        _shell = State(initialValue: IOSShell())
    }

    public var body: some Scene {
        WindowGroup("Lazy PDF") {
            IOSRoot(shell: shell)
        }
        .commands { ViewerCommands() }
    }
}
#endif
