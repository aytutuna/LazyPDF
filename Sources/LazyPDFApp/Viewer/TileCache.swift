import Foundation

// Port of windows/LazyPDF.App/Viewer/TileCache.cs. The picture type is the surface's own; the cache only needs to know how
// many pixels it holds.

public protocol PixelSized {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
}

/// The pictures drawn so far, least recently used out first once their pixels pass a budget. Used from one thread.
public final class TileCache<Picture: PixelSized> {
    private var entries: [TileKey: (picture: Picture, used: Int)] = [:]
    private var byPage: [Int: Set<TileKey>] = [:]
    private var tick = 0

    public let budget: Int

    /// Bytes of pixels held.
    public private(set) var bytes = 0

    public init(budget: Int) {
        self.budget = budget
    }

    public var count: Int { entries.count }

    public func contains(_ key: TileKey) -> Bool {
        entries[key] != nil
    }

    /// The picture, counted as just used.
    public func get(_ key: TileKey) -> Picture? {
        guard let entry = entries[key] else { return nil }
        tick += 1
        entries[key] = (entry.picture, tick)
        return entry.picture
    }

    /// Adds a picture and lets go of the least recently used until the budget holds; the one just added stays.
    public func add(_ key: TileKey, _ picture: Picture) {
        remove(key)
        tick += 1
        entries[key] = (picture, tick)
        byPage[key.page, default: []].insert(key)
        bytes += Self.size(picture)
        while bytes > budget && entries.count > 1, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            remove(oldest.key)
        }
    }

    /// The keys held for a page, without counting them as used.
    public func keys(_ page: Int) -> Set<TileKey> {
        byPage[page] ?? []
    }

    /// The picture, not counted as used: the drawing reads many and marks only the ones it shows.
    public func peek(_ key: TileKey) -> Picture? {
        entries[key]?.picture
    }

    public func remove(_ key: TileKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= Self.size(entry.picture)
        byPage[key.page]?.remove(key)
        if byPage[key.page]?.isEmpty == true { byPage[key.page] = nil }
    }

    public func removeWhere(_ page: Int, _ match: (TileKey) -> Bool) {
        for key in keys(page) where match(key) { remove(key) }
    }

    /// Lets go of every picture whose key `keep` refuses.
    public func trim(keeping keep: (TileKey) -> Bool) {
        for key in Array(entries.keys) where !keep(key) { remove(key) }
    }

    public func clear() {
        entries.removeAll()
        byPage.removeAll()
        bytes = 0
    }

    private static func size(_ picture: Picture) -> Int {
        picture.pixelWidth * picture.pixelHeight * 4
    }
}
