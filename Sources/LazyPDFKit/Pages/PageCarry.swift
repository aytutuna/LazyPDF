import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageCarry.cs: what a new document keeps of the source besides the pages: the
// bookmarks, labels, named destinations, attached files and tag tree of the pages taken, and the language and XMP of the document.
// Runs once the pages are in the target's tree, since destinations are written by page index.
enum PageCarry {
    private static let maxTagElements = 200_000

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

    /// Whether the source has a tag tree small enough to carry.
    static func hasTags(_ source: PdfDocument) -> Bool {
        guard let root = source.dict(source.catalog, "StructTreeRoot") else { return false }
        var seen = Set<ObjectIdentifier>()
        var open = [root]
        while let element = open.popLast() {
            if !seen.insert(ObjectIdentifier(element)).inserted { continue }
            if seen.count >= maxTagElements { return false }
            let kids = source.resolve(element["K"])
            let list: [PdfObject] = (kids as? PdfArray)?.items ?? (kids.map { [$0] } ?? [])
            for kid in list {
                if let child = source.resolve(kid) as? PdfDictionary { open.append(child) }
            }
        }
        return true
    }

    /// The source's tag tree cut to the pages taken, which `copies` are the copies of; the importer kept their keys.
    static func tags(_ source: PdfDocument, _ target: PdfDocument, _ importer: PageImporter, _ copies: [PdfReference]) throws {
        _ = try pruned(source, target, importer, copies)
        if let mark = source.catalog["MarkInfo"] { target.catalog["MarkInfo"] = try importer.copyValue(mark) }
    }

    /// One tag tree for a merge: the kids of each source's pruned tree under a new root, with the keys of the later
    /// sources moved past those of the earlier. `all` is whether every source with pages is in `tagged`.
    static func mergeTags(_ target: PdfDocument, _ tagged: [(source: PdfDocument, importer: PageImporter, copies: [PdfReference])], _ all: Bool) throws {
        if tagged.isEmpty { return }
        let root = PdfDictionary()
        root["Type"] = PdfName("StructTreeRoot")
        let rootRef = try target.add(root)
        var kids: [PdfObject] = []
        let roles = PdfDictionary()
        var parents: [(key: Int, value: PdfObject)] = []
        var next = 0
        for entry in tagged {
            let tree = try pruned(entry.source, target, entry.importer, entry.copies)
            var end = next
            for (holder, key) in holders(target, entry.copies) {
                guard let number = target.integer(holder, key) else { continue }
                holder[key] = PdfNumber(number + next)
                end = max(end, number + next + 1)
            }
            for item in PdfNumberTree.read(target, tree["ParentTree"]) {
                parents.append((item.key + next, item.value))
                end = max(end, item.key + next + 1)
            }
            next = end
            let own = tree["K"]
            let list: [PdfObject] = (target.resolve(own) as? PdfArray)?.items ?? (own.map { [$0] } ?? [])
            for kid in list {
                if let element = target.resolve(kid) as? PdfDictionary, element.containsKey("P") { element["P"] = rootRef }
                kids.append(kid)
            }
            if let map = target.dict(tree, "RoleMap") {
                for (name, role) in map.entries where !roles.containsKey(name) { roles[name] = role }
            }
        }
        root["K"] = PdfArray(kids)
        root["ParentTree"] = try target.add(try PdfNumberTree.write(target, nil, parents))
        root["ParentTreeNextKey"] = PdfNumber(next)
        if roles.count > 0 { root["RoleMap"] = roles }
        target.catalog["StructTreeRoot"] = rootRef
        if all {
            let mark = PdfDictionary()
            mark["Marked"] = PdfBoolean(true)
            target.catalog["MarkInfo"] = mark
        }
    }

    // The tree is the catalog's until a merge replaces it, since the pruner works on the catalog's.
    private static func pruned(_ source: PdfDocument, _ target: PdfDocument, _ importer: PageImporter, _ copies: [PdfReference]) throws -> PdfDictionary {
        let page = PdfDictionary()
        page["Type"] = PdfName("Page")
        let ghost = try target.add(page)
        target.catalog["StructTreeRoot"] = try importer.copyTree(source.catalog["StructTreeRoot"]!, ghost)
        try RedactionStructure.prune(target, [:], RedactionObjects.Identities(), [ghost.number])
        target.delete(ghost.number)
        let root = target.dict(target.catalog, "StructTreeRoot")!
        let used = Set(holders(target, copies).compactMap { target.integer($0.holder, $0.key) })
        if let parents = target.dict(root, "ParentTree") {
            _ = try PdfNumberTree.write(target, parents, PdfNumberTree.read(target, parents).filter { used.contains($0.key) })
        }
        return root
    }

    // Where a key into the parent tree is written: the pages and their annotations.
    private static func holders(_ target: PdfDocument, _ copies: [PdfReference]) -> [(holder: PdfDictionary, key: String)] {
        var found: [(holder: PdfDictionary, key: String)] = []
        for copy in copies {
            guard let page = target.resolve(copy) as? PdfDictionary else { continue }
            found.append((page, "StructParents"))
            for item in target.array(page, "Annots")?.items ?? [] {
                if let annotation = target.resolve(item) as? PdfDictionary { found.append((annotation, "StructParent")) }
            }
        }
        return found
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
