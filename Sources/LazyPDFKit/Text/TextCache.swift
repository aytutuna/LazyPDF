import Foundation

// Twin of windows/LazyPDF.Core/Text/TextCache.cs: the text pages of one document, built when first asked for and kept
// while their characters stay under a cap, the least recently used going first. Safe for several threads asking, but
// the document is read under a lock: a `PdfDocument` is not safe to share.

public final class TextCache {
    private let document: PdfDocument
    private let maxChars: Int
    private let lock = NSLock()
    private var pages: [Int: (page: TextPage, used: Int)] = [:]
    private var interpreter: ContentInterpreter?
    private var chars = 0
    private var tick = 0

    public init(_ document: PdfDocument, maxChars: Int = 2_000_000) {
        self.document = document
        self.maxChars = maxChars
    }

    public var pageCount: Int { document.pages.count }

    public func get(_ pageIndex: Int) -> TextPage {
        lock.lock()
        defer { lock.unlock() }
        tick += 1
        if let known = pages[pageIndex] {
            pages[pageIndex] = (known.page, tick)
            return known.page
        }
        let reader = interpreter ?? ContentInterpreter(document)
        interpreter = reader
        let page = TextPage.create(reader, document.pages[pageIndex])
        pages[pageIndex] = (page, tick)
        chars += page.chars.count
        while chars > maxChars && pages.count > 1 {
            guard let oldest = pages.min(by: { $0.value.used < $1.value.used }) else { break }
            pages[oldest.key] = nil
            chars -= oldest.value.page.chars.count
        }
        return page
    }

    /// Forgets every page, after the document was edited.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        pages.removeAll()
        chars = 0
    }
}
