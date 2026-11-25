#if os(iOS)
import Foundation
import LazyPDFApp

// The app's container: settings and recovery copies in Application Support, thumbnails in Caches, what another program
// has to read in tmp. The app has the container to itself, so there is no folder of its own inside them.

public struct IOSAppFolders: AppFolders {
    private let support: URL
    private let caches: URL
    private let temporary: URL

    public init() {
        let manager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Caches", isDirectory: true)
        temporary = manager.temporaryDirectory
    }

    public var settings: URL { support }

    public var recovery: URL { support.appendingPathComponent("Recovery", isDirectory: true) }

    public var thumbnails: URL { caches.appendingPathComponent("Thumbnails", isDirectory: true) }

    public var printCopies: URL { temporary.appendingPathComponent("Print", isDirectory: true) }

    public var openedAttachments: URL { temporary.appendingPathComponent("Attachments", isDirectory: true) }
}
#endif
