import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageAssembly.cs: new documents made of pages of others. A new document holds the
// pages asked for and what they use and nothing else: no tree, outlines, names or tags of the source, no resource a page
// only lists. Page labels, bookmarks and article threads are not carried over.
//
// The C# CancellationToken is the task's: the checks are `Task.checkCancellation()`. A call with no page to take throws
// where the C# throws ArgumentException, since a source with no pages can come from a file.

/// A document to merge and the pages of it to take (0-based, in the order given); nil takes them all.
public struct MergeSource {
    public let document: PdfDocument
    public let pages: [Int]?

    public init(_ document: PdfDocument, _ pages: [Int]? = nil) {
        self.document = document
        self.pages = pages
    }
}

public enum PageAssembly {
    /// A document of the pages at these indexes, in this order. Keeps the source's /Info. Throws `CancellationError`
    /// when the task is cancelled.
    public static func extract(_ source: PdfDocument, _ pages: [Int]) throws -> PdfDocument {
        if pages.isEmpty { throw PdfReadException.damaged("There are no pages to take.") }
        let target = try blank(source.version)
        let importer = PageImporter(source, target)
        let copies = try importer.importPages(pages)
        if let info = source.trailer["Info"], source.info != nil { target.trailer["Info"] = try importer.copyValue(info) }
        try PageTree.set(target, copies)
        return target
    }

    /// The pages of each source one after the other. A document listed twice is copied once. Cancellation is checked
    /// between documents and between pages.
    public static func merge(_ sources: [MergeSource]) throws -> PdfDocument {
        precondition(!sources.isEmpty, "There is nothing to merge.")
        var version = sources[0].document.version
        for source in sources.dropFirst() {
            if let newer = SystemVersion(source.document.version), let current = SystemVersion(version), newer > current { version = source.document.version }
        }
        let target = try blank(version)
        var importers: [ObjectIdentifier: PageImporter] = [:]
        var order: [PdfReference] = []
        var origins: [AnyObject] = []
        for source in sources {
            try Task.checkCancellation()
            let id = ObjectIdentifier(source.document)
            let importer = importers[id] ?? PageImporter(source.document, target)
            importers[id] = importer
            let copies = try importer.importPages(source.pages ?? Array(0..<source.document.pages.count))
            order.append(contentsOf: copies)
            origins.append(contentsOf: copies.map { _ in source.document })
        }
        if order.isEmpty { throw PdfReadException.damaged("The sources have no pages.") }
        let first = sources[0].document
        if let info = first.trailer["Info"], first.info != nil, let importer = importers[ObjectIdentifier(first)] {
            target.trailer["Info"] = try importer.copyValue(info)
        }
        try PageTree.set(target, order)
        try StampRuns.separate(target, zip(target.pages, origins).map { (page: $0, origin: $1) })
        return target
    }

    /// Parts of `count` pages each; the last holds what is left.
    public static func splitEvery(_ source: PdfDocument, _ count: Int) throws -> [PdfDocument] {
        precondition(count >= 1, "count")
        let total = source.pages.count
        let parts = total == 0 ? 0 : (total - 1) / count + 1
        return try splitByRanges(source, (0..<parts).map { p in Array(p * count..<p * count + min(count, total - p * count)) })
    }

    /// One part for each list of pages.
    public static func splitByRanges(_ source: PdfDocument, _ parts: [[Int]]) throws -> [PdfDocument] {
        try parts.map { try extract(source, $0) }
    }

    /// A new part starts at each of these pages (0-based); the first part starts at page 0. Where bookmarks of the top
    /// level point is a good list.
    public static func splitAt(_ source: PdfDocument, _ starts: [Int]) throws -> [PdfDocument] {
        let total = source.pages.count
        var cuts = Set(starts.filter { $0 != 0 }).sorted()
        precondition(!cuts.contains { $0 < 0 || $0 >= total }, "starts")
        cuts.insert(0, at: 0)
        cuts.append(total)
        return try splitByRanges(source, (0..<cuts.count - 1).map { Array(cuts[$0]..<cuts[$0 + 1]) })
    }

    /// Parts that each save (`saveRewrite` with `options`) to no more than `maxBytes`, as many pages as fit. A page that is
    /// bigger alone is a part of its own. The size of a part is measured by saving it, starting from an estimate out of the
    /// size of the source, so the work is a few saves of each part; the document that fit is the part. Cancellation is
    /// checked before each save.
    public static func splitBySize(_ source: PdfDocument, _ maxBytes: Int, _ options: PdfSaveOptions = PdfSaveOptions()) throws -> [PdfDocument] {
        precondition(maxBytes >= 1, "maxBytes")
        let total = source.pages.count
        var fitted: [Int: PdfDocument] = [:]
        func fits(_ start: Int, _ length: Int) throws -> Bool {
            let candidate = try extract(source, Array(start..<start + length))
            if try candidate.saveRewrite(options).count > maxBytes { return false }
            fitted[length] = candidate
            return true
        }

        var parts: [PdfDocument] = []
        var at = 0
        while at < total {
            fitted.removeAll()
            let remaining = total - at
            var low = 1, high = remaining + 1
            if remaining > 1 {
                let guess = Int(min(max(Double(maxBytes) * Double(total) / Double(max(source.length, 1)), 2), Double(remaining)))
                if try fits(at, guess) {
                    low = guess
                    var step = 1
                    while low + step < high {
                        if try fits(at, low + step) {
                            low += step
                        } else {
                            high = low + step
                            break
                        }
                        step *= 2
                    }
                } else {
                    high = guess
                    var step = 1
                    while high - step > low {
                        if try fits(at, high - step) {
                            low = high - step
                            break
                        }
                        high -= step
                        step *= 2
                    }
                }
                while low + 1 < high {
                    let mid = (low + high) / 2
                    if try fits(at, mid) { low = mid } else { high = mid }
                }
            }
            parts.append(try fitted[low] ?? extract(source, Array(at..<at + low)))
            at += low
        }
        return parts
    }

    // A file of a catalog and an empty tree, with a proper table so that opening it needs no repair.
    private static func blank(_ version: String) throws -> PdfDocument {
        let head = "%PDF-\(version)\n%\u{E2}\u{E3}\u{CF}\u{D3}\n"
        let catalog = "1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n"
        let tree = "2 0 obj\n<</Type /Pages /Kids [] /Count 0>>\nendobj\n"
        let first = head.unicodeScalars.count, second = first + catalog.unicodeScalars.count
        let table = second + tree.unicodeScalars.count
        let end = "xref\n0 3\n0000000000 65535 f \n" + String(format: "%010ld", first) + " 00000 n \n" + String(format: "%010ld", second)
            + " 00000 n \ntrailer\n<</Size 3 /Root 1 0 R>>\nstartxref\n\(table)\n%%EOF\n"
        return try PdfDocument.open(Latin1.bytes(head + catalog + tree + end))
    }
}
