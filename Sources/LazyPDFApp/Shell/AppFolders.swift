import Foundation

// Follows windows/LazyPDF.App/Services/AppFolders.cs. The apps pass their own folders in; tests pass a temporary one.

/// Where the app keeps files. Settings and recovery copies sit in Application Support, thumbnails in the caches. A file
/// another program has to read goes in the temporary folder.
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
    public init() {}

    public var settings: URL { Self.support }

    public var recovery: URL { Self.support.appendingPathComponent("Recovery", isDirectory: true) }

    public var thumbnails: URL { Self.caches.appendingPathComponent("Thumbnails", isDirectory: true) }

    public var printCopies: URL { Self.temporary.appendingPathComponent("Print", isDirectory: true) }

    public var openedAttachments: URL { Self.temporary.appendingPathComponent("Attachments", isDirectory: true) }

    private static var support: URL { folder(.applicationSupportDirectory, "Library/Application Support") }

    private static var caches: URL { folder(.cachesDirectory, "Library/Caches") }

    private static var temporary: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Lazy PDF", isDirectory: true)
    }

    private static func folder(_ kind: FileManager.SearchPathDirectory, _ fallback: String) -> URL {
        let base = FileManager.default.urls(for: kind, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(fallback, isDirectory: true)
        return base.appendingPathComponent("Lazy PDF", isDirectory: true)
    }
}
