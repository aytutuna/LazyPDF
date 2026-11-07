#if os(macOS)
import Foundation
import LazyPDFApp

// Follows windows/LazyPDF.App/Services/AppFolders.cs. In the sandbox the system folders are inside the app's container.
// Copies for Lazy Print sit in the caches, since the sister app reads them after this one has handed them over and the
// temporary folder is cleared sooner.

struct MacAppFolders: AppFolders {
    private let support: URL
    private let caches: URL
    private let temporary: URL

    init() {
        let files = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Caches", isDirectory: true)
        self.init(support: support, caches: caches, temporary: files.temporaryDirectory)
    }

    init(support: URL, caches: URL, temporary: URL) {
        self.support = support.appendingPathComponent("Lazy PDF", isDirectory: true)
        self.caches = caches.appendingPathComponent("Lazy PDF", isDirectory: true)
        self.temporary = temporary.appendingPathComponent("Lazy PDF", isDirectory: true)
    }

    var settings: URL { support }

    var recovery: URL { support.appendingPathComponent("Recovery", isDirectory: true) }

    var thumbnails: URL { caches.appendingPathComponent("Thumbnails", isDirectory: true) }

    var printCopies: URL { caches.appendingPathComponent("Print", isDirectory: true) }

    var openedAttachments: URL { temporary.appendingPathComponent("Attachments", isDirectory: true) }
}
#endif
