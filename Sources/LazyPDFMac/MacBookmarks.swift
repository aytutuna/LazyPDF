#if os(macOS)
import Foundation
import LazyPDFApp

// The Mac side of Bookmarks. The sandbox lets the app open a recent file again only through the app-scoped bookmark made
// when the file was chosen.

final class MacBookmarks: Bookmarks {
    func make(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // No UI and no mounting, so an unplugged network volume cannot stall the window that resolves every recent file.
    func resolve(_ bookmark: Data) -> ResolvedBookmark? {
        var stale = false
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return ResolvedBookmark(url: url, stale: stale)
    }

    func access(_ url: URL) -> FileAccess? {
        SecurityScopedAccess.start(url)
    }
}
#endif
