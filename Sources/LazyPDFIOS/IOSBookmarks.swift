#if os(iOS)
import Foundation
import LazyPDFApp

// iOS has no app-scope bookmark option: a URL from the document picker or Files carries its security scope, and the
// bookmark made from it keeps the grant.

public struct IOSBookmarks: Bookmarks {
    public init() {}

    public func make(_ url: URL) -> Data? {
        try? url.bookmarkData()
    }

    public func resolve(_ bookmark: Data) -> ResolvedBookmark? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return ResolvedBookmark(url: url, stale: stale)
    }

    public func access(_ url: URL) -> FileAccess? {
        SecurityScopedAccess.start(url)
    }
}

/// A started security-scoped access, ended once by `stop` or, failing that, when the object goes.
public final class SecurityScopedAccess: FileAccess {
    private let url: URL
    private let end: (URL) -> Void
    private let lock = NSLock()
    private var active = true

    /// Nil when the system refused access.
    public static func start(_ url: URL) -> SecurityScopedAccess? {
        url.startAccessingSecurityScopedResource() ? SecurityScopedAccess(url) { $0.stopAccessingSecurityScopedResource() } : nil
    }

    /// For access started already; `stop` runs when it ends.
    public init(_ url: URL, stop: @escaping (URL) -> Void) {
        self.url = url
        end = stop
    }

    public func stop() {
        lock.lock()
        let was = active
        active = false
        lock.unlock()
        if was { end(url) }
    }

    deinit {
        stop()
    }
}
#endif
