import Foundation
import LazyPDFKit

// Port of windows/LazyPDF.App/Viewer/TextSource.cs.

/// The text of one revision of a file: its pages as `TextPage`s, made off the main actor from a document of the viewer's
/// own, since the tab's document belongs to the main actor and to whatever tool is editing it. One source is made per
/// revision and dropped when the file changes.
public final class TextSource: @unchecked Sendable {
    // Pages of text are far bigger in memory than on the page: a character is an object with its box. This keeps the
    // pages read for the window and a search, a few hundred, not the file.
    private static let cachedCharacters = 300_000

    // Pages handed out and still at hand for `peek`; the rest are read again from the cache, or the file.
    private static let recent = 48

    private let cache: TextCache
    private let lock = NSLock()
    private var pages: [Int: Task<TextPage?, Never>] = [:]
    private var ready: [Int: TextPage] = [:]
    private var order: [Int] = []
    private var keep = TextSource.recent

    public let pageCount: Int

    private init(_ document: PdfDocument) {
        cache = TextCache(document, maxChars: Self.cachedCharacters)
        pageCount = cache.pageCount
    }

    /// Reads the bytes again for text; nil when the engine cannot open them with what the tab was opened with.
    public static func open(_ bytes: [UInt8], password: String?) async -> TextSource? {
        await open { try PdfDocument.open(bytes, password: password) }
    }

    #if canImport(Security)
    public static func open(_ bytes: [UInt8], certificate: PdfCertificate) async -> TextSource? {
        await open { try PdfDocument.open(bytes, certificate: certificate) }
    }
    #endif

    private static func open(_ make: @escaping () throws -> PdfDocument) async -> TextSource? {
        await Task.detached { () -> TextSource? in
            do {
                return TextSource(try make())
            } catch {
                return nil
            }
        }.value
    }

    /// Keeps at least the text of `visible` pages at hand, so a window full of selected pages does not push its own pages out.
    public func retain(_ visible: Int) {
        lock.lock()
        keep = Swift.max(Self.recent, visible + 8)
        lock.unlock()
    }

    /// The text of a page if it has been made already.
    public func peek(_ page: Int) -> TextPage? {
        lock.lock()
        defer { lock.unlock() }
        return ready[page]
    }

    /// The text of a page, made on first use.
    public func get(_ page: Int) async -> TextPage? {
        guard page >= 0 && page < pageCount else { return nil }
        return await task(page).value
    }

    private func task(_ page: Int) -> Task<TextPage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let known = pages[page] { return known }
        let made = Task.detached { [self] () -> TextPage? in
            let text = cache.get(page)
            remember(page, text)
            return text
        }
        pages[page] = made
        order.append(page)
        while order.count > keep {
            let old = order.removeFirst()
            pages[old] = nil
            ready[old] = nil
        }
        return made
    }

    private func remember(_ page: Int, _ text: TextPage) {
        lock.lock()
        defer { lock.unlock() }
        if pages[page] != nil { ready[page] = text }
    }

    /// Every match, page by page, as they are found. Throws for a regular expression that does not parse; reading the
    /// sequence stops with `CancellationError` when the task is cancelled.
    public func find(_ query: String, _ options: TextSearchOptions) throws -> TextSearch.Hits {
        try TextSearch.find(cache, query, options)
    }

    /// The text of a page for the search task, which does not go through `get`.
    public func page(_ page: Int) -> TextPage {
        cache.get(page)
    }
}
