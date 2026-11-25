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
#endif
