import Foundation

// Follows windows/LazyPDF.App/Services/AppFolders.cs. The apps pass their own folders in; tests pass a temporary one.

/// Where the app keeps files. Settings and recovery copies sit in Application Support, thumbnails in the caches. A file
/// another program has to read (the copies for Lazy Print) goes in the caches, which are cleared later than the temporary
/// folder. In the Mac sandbox all of them are inside the app's container.
public protocol AppFolders {
    var settings: URL { get }
    var recovery: URL { get }
    var thumbnails: URL { get }
    /// The copies of open documents handed to Lazy Print.
    var printCopies: URL { get }
    /// Attachments opened in the program that handles their type.
    var openedAttachments: URL { get }
}

public struct DefaultAppFolders: AppFolders {
    private let support: URL
    private let caches: URL
    private let temporary: URL

    public init() {
        let files = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Caches", isDirectory: true)
        self.init(support: support, caches: caches, temporary: files.temporaryDirectory)
    }

    public init(support: URL, caches: URL, temporary: URL) {
        self.support = support.appendingPathComponent("Lazy PDF", isDirectory: true)
        self.caches = caches.appendingPathComponent("Lazy PDF", isDirectory: true)
        self.temporary = temporary.appendingPathComponent("Lazy PDF", isDirectory: true)
    }

    public var settings: URL { support }

    public var recovery: URL { support.appendingPathComponent("Recovery", isDirectory: true) }

    public var thumbnails: URL { caches.appendingPathComponent("Thumbnails", isDirectory: true) }

    public var printCopies: URL { caches.appendingPathComponent("Print", isDirectory: true) }

    public var openedAttachments: URL { temporary.appendingPathComponent("Attachments", isDirectory: true) }
}
