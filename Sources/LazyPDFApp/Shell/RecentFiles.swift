import Foundation

// Follows windows/LazyPDF.App/Services/RecentFiles.cs. A sandboxed app can open a file again only through the bookmark
// it made when the file was chosen, so the list keeps bookmarks, with the path as what is shown and compared.

/// Makes and resolves the bookmarks of recent files. The Mac and iOS apps implement it with security-scoped bookmarks;
/// tests keep the path in the bytes.
public protocol Bookmarks {
    /// Nil when the system will not make one.
    func make(_ url: URL) -> Data?

    /// Nil when the file cannot be found through the bookmark any more.
    func resolve(_ bookmark: Data) -> URL?
}

/// A file in the recent list: where it was, how to get back to it, and when it was last opened.
public struct RecentFile: Codable, Equatable {
    public var path = ""
    public var bookmark = Data()
    public var opened = Date(timeIntervalSince1970: 0)

    public init(path: String, bookmark: Data, opened: Date) {
        self.path = path
        self.bookmark = bookmark
        self.opened = opened
    }

    private enum CodingKeys: String, CodingKey {
        case path, bookmark, opened
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.decodeLenient(forKey: .path, default: path)
        bookmark = c.decodeLenient(forKey: .bookmark, default: bookmark)
        opened = c.decodeLenient(forKey: .opened, default: opened)
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
        let path = Self.key(url)
        var files = load().filter { !Self.same($0.path, path) }
        files.insert(RecentFile(path: path, bookmark: bookmarks.make(url) ?? Data(), opened: now), at: 0)
        StoreFiles.write(RecentList(files: Array(files.prefix(Self.limit))), to: file)
    }

    public func remove(_ url: URL) {
        let path = Self.key(url)
        StoreFiles.write(RecentList(files: load().filter { !Self.same($0.path, path) }), to: file)
    }

    public func clear() {
        StoreFiles.write(RecentList(), to: file)
    }

    /// Where the file is now: through its bookmark, else by the path it had.
    public func locate(_ recent: RecentFile) -> URL {
        (recent.bookmark.isEmpty ? nil : bookmarks.resolve(recent.bookmark)) ?? URL(fileURLWithPath: recent.path)
    }

    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    // The Mac's volumes are case-insensitive unless the user made one otherwise, as Windows' are.
    static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }
}
