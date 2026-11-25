import Foundation

// Follows windows/LazyPDF.App/Services/RecentFiles.cs. A sandboxed app can open a file again only through the bookmark
// it made when the file was chosen, so the list keeps bookmarks, with the path as what is shown and compared.

/// What a bookmark led to, and whether the system wants it made again.
public struct ResolvedBookmark {
    public let url: URL
    public let stale: Bool

    public init(url: URL, stale: Bool) {
        self.url = url
        self.stale = stale
    }
}

/// A grant to use a file outside the app's own folders, held until `stop` is called. Calling `stop` twice does no harm.
public protocol FileAccess: AnyObject {
    func stop()
}

/// Makes and resolves the bookmarks of recent files. The Mac and iOS apps implement it with security-scoped bookmarks;
/// tests keep the path in the bytes.
public protocol Bookmarks {
    /// Nil when the system will not make one.
    func make(_ url: URL) -> Data?

    /// Nil when the file cannot be found through the bookmark any more. It must not start security-scoped access, since
    /// the recent list resolves every entry on the main actor after each open; it must also pass `.withoutUI` and
    /// `.withoutMounting`, so an unplugged network volume cannot stall the window.
    func resolve(_ bookmark: Data) -> ResolvedBookmark?

    /// Starts access to a url that came from `resolve`, for a file about to be opened. Nil when no access is needed or it
    /// was refused. The shell stops it when the file is no longer held.
    func access(_ url: URL) -> FileAccess?
}

/// A file in the recent list: where it was, how to get back to it, and when it was last opened.
public struct RecentFile: Codable, Equatable {
    public var path = ""
    public var bookmark = Data()
    public var opened = Date(timeIntervalSince1970: 0)

    /// Where the file was left: the page (0-based), the zoom (0 for none) and the fit mode.
    public var page = 0
    public var zoom = 0.0
    public var fit = FitMode.none

    public init(path: String, bookmark: Data, opened: Date, page: Int = 0, zoom: Double = 0, fit: FitMode = .none) {
        self.path = path
        self.bookmark = bookmark
        self.opened = opened
        self.page = page
        self.zoom = zoom
        self.fit = fit
    }

    private enum CodingKeys: String, CodingKey {
        case path, bookmark, opened, page, zoom, fit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.decodeLenient(forKey: .path, default: path)
        bookmark = c.decodeLenient(forKey: .bookmark, default: bookmark)
        opened = c.decodeLenient(forKey: .opened, default: opened)
        page = c.decodeLenient(forKey: .page, default: page)
        zoom = c.decodeLenient(forKey: .zoom, default: zoom)
        fit = c.decodeLenient(forKey: .fit, default: fit)
    }
}

struct RecentList: Codable {
    var files: [RecentFile] = []

    init(files: [RecentFile] = []) {
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = c.decodeLenient(forKey: .files, default: files)
    }

    private enum CodingKeys: String, CodingKey {
        case files
    }
}

/// The files opened last, newest first, in recent.json beside the preferences.
public final class RecentFiles {
    public static let limit = 24

    private let file: URL
    private let bookmarks: Bookmarks

    public init(directory: URL, bookmarks: Bookmarks) {
        file = directory.appendingPathComponent("recent.json")
        self.bookmarks = bookmarks
    }

    public func load() -> [RecentFile] {
        let files = StoreFiles.load(RecentList.self, from: file)?.files ?? []
        return Array(files.filter { !$0.path.isEmpty }.prefix(Self.limit))
    }

    public func add(_ url: URL, now: Date = Date()) {
        let all = load()
        let kept = all.first { matches($0, url) }
        let files = all.filter { !matches($0, url) }
        let entry = RecentFile(path: Self.key(url), bookmark: bookmarks.make(url) ?? Data(), opened: now,
                               page: kept?.page ?? 0, zoom: kept?.zoom ?? 0, fit: kept?.fit ?? .none)
        write([entry] + files)
    }

    /// Keeps where the file was left for the next time it is opened; a file that is not listed is ignored.
    public func rememberView(_ url: URL, page: Int, zoom: Double, fit: FitMode) {
        var files = load()
        guard let at = files.firstIndex(where: { matches($0, url) }) else { return }
        files[at].page = page
        files[at].zoom = zoom
        files[at].fit = fit
        write(files)
    }

    /// What was remembered for the file, if it is listed.
    public func view(of url: URL) -> RecentFile? {
        load().first { matches($0, url) }
    }

    /// Takes out the entry for the file, whether it is stored under this path or its bookmark now leads here.
    public func remove(_ url: URL) {
        write(load().filter { !matches($0, url) })
    }

    public func clear() {
        write([])
    }

    /// Where the file is now: through its bookmark, else by the path it had. A stale bookmark is made again.
    public func locate(_ recent: RecentFile) -> URL {
        if !recent.bookmark.isEmpty, let found = bookmarks.resolve(recent.bookmark) {
            if found.stale, let fresh = bookmarks.make(found.url) { refresh(recent, fresh) }
            return found.url
        }
        return URL(fileURLWithPath: recent.path)
    }

    private func matches(_ recent: RecentFile, _ url: URL) -> Bool {
        if Self.sameFile(URL(fileURLWithPath: recent.path), url) { return true }
        guard !recent.bookmark.isEmpty, let found = bookmarks.resolve(recent.bookmark) else { return false }
        return Self.sameFile(found.url, url)
    }

    private func refresh(_ recent: RecentFile, _ bookmark: Data) {
        var files = load()
        guard let at = files.firstIndex(where: { $0.path == recent.path }) else { return }
        files[at].bookmark = bookmark
        write(files)
    }

    private func write(_ files: [RecentFile]) {
        StoreFiles.write(RecentList(files: Array(files.prefix(Self.limit))), to: file)
    }

    /// The path with symlinks resolved and accents composed, so one file has one spelling.
    static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    /// `key`, folded to lower case unless the volume says names differ by case (the Mac's usually do not).
    static func folded(_ url: URL) -> String {
        caseSensitive(url) ? key(url) : key(url).lowercased()
    }

    /// The same file by the system's own identity when both exist, else by name.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if let x = identity(a), let y = identity(b) { return x.isEqual(y) }
        return folded(a) == folded(b)
    }

    private static func identity(_ url: URL) -> NSObjectProtocol? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }

    private static func caseSensitive(_ url: URL) -> Bool {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return (try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == true
    }
}
