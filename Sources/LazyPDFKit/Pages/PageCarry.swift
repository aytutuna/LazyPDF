import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageCarry.cs: what a new document keeps of the source besides the pages: the
// bookmarks, labels, named destinations and attached files of the pages taken, and the language and XMP of the document.
// Runs once the pages are in the target's tree, since destinations are written by page index.
enum PageCarry {
    /// Carries what belongs to the source pages at `sourcePages`, which are the target's pages from `firstNewIndex` on.
    /// `mergeTitle` is set for one source of a merge: its bookmarks go under an item with that title and no labels are written.
    static func carry(_ source: PdfDocument, _ target: PdfDocument, _ sourcePages: [Int], _ firstNewIndex: Int, _ mergeTitle: String? = nil) throws {
        var newIndex: [Int: Int] = [:]
        for (i, page) in sourcePages.enumerated() where newIndex[page] == nil { newIndex[page] = firstNewIndex + i }
        try bookmarks(source, target, newIndex, mergeTitle)
        if mergeTitle == nil { try labels(source, target, sourcePages) }
        try namedDestinations(source, target, newIndex)
        for file in PdfAttachments.list(source) where file.pageIndex == nil {
            try PdfAttachments.add(target, file.fileName, try PdfAttachments.extract(source, file), mimeType: file.mimeType,
                                   description: file.description, created: file.created, modified: file.modified)
        }
    }

    /// The source's /Lang, and its XMP when the target has the /Info as well.
    static func catalog(_ source: PdfDocument, _ target: PdfDocument, _ importer: PageImporter) throws {
        if let lang = source.catalog["Lang"] { target.catalog["Lang"] = try importer.copyValue(lang) }
        if target.trailer["Info"] != nil, let xmp = source.catalog["Metadata"] { target.catalog["Metadata"] = try importer.copyValue(xmp) }
    }

    private static func bookmarks(_ source: PdfDocument, _ target: PdfDocument, _ newIndex: [Int: Int], _ mergeTitle: String?) throws {
        let outline = Outline.read(target)
        let kept = try Outline.read(source).items.compactMap { try keep(outline, $0, newIndex) }
        if kept.isEmpty { return }
        var parent: OutlineItem?
        if let title = mergeTitle {
            let wrapper = OutlineItem()
            wrapper.title = title
            wrapper.isOpen = true
            parent = try outline.add(wrapper)
        }
        for item in kept { try outline.add(item, parent) }
        try outline.write(target)
    }

    // An item stays when it points at a page taken or when something under it does; it then goes to the page's new place.
    private static func keep(_ outline: Outline, _ item: OutlineItem, _ newIndex: [Int: Int]) throws -> OutlineItem? {
        let children = try item.children.compactMap { try keep(outline, $0, newIndex) }
        var destination: PdfDestination?
        if var d = item.destination, let at = newIndex[d.pageIndex] {
            d.pageIndex = at
            d.name = nil
            destination = d
        }
        if destination == nil && children.isEmpty { return nil }
        let copy = OutlineItem()
        copy.title = item.title
        copy.color = item.color
        copy.bold = item.bold
        copy.italic = item.italic
        copy.isOpen = item.isOpen
        copy.destination = destination
        for child in children { try outline.add(child, copy) }
        return copy
    }

    private static func labels(_ source: PdfDocument, _ target: PdfDocument, _ sourcePages: [Int]) throws {
        let ranges = PdfPageLabels.read(source)
        if ranges.isEmpty { return }
        var carried: [PageLabelRange] = []
        var last: PageLabelRange?
        for (i, page) in sourcePages.enumerated() {
            let range = ranges.filter { $0.startPage <= page }.max { $0.startPage < $1.startPage } ?? PageLabelRange(0)
            // A range that has a gap in the pages taken goes on counting where the source does.
            if range != last || page != sourcePages[i - 1] + 1 {
                carried.append(PageLabelRange(i, range.style, range.prefix, range.firstNumber + page - range.startPage))
            }
            last = range
        }
        try PdfPageLabels.write(target, carried)
    }

    private static func namedDestinations(_ source: PdfDocument, _ target: PdfDocument, _ newIndex: [Int: Int]) throws {
        let found = PdfDestinations.named(source).filter { newIndex[$0.value.pageIndex] != nil }
        if found.isEmpty { return }
        let names = PdfNames.ensure(target)
        let tree = target.dict(names, "Dests")
        var entries = PdfNameTree.read(target, tree)
        let taken = Set(entries.map { $0.key })
        for (name, destination) in found {
            // Two sources of a merge may use the same name; the first keeps it.
            var moved = destination
            moved.pageIndex = newIndex[destination.pageIndex]!
            moved.name = nil
            guard !taken.contains(name), let value = PdfDestinations.toObject(target, moved) else { continue }
            entries.append((key: name, value: value))
        }
        let root = try PdfNameTree.write(target, tree, entries)
        if tree == nil { names["Dests"] = try target.add(root) }
    }
}
