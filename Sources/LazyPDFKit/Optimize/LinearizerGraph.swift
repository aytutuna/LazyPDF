import Foundation

// Twin of windows/LazyPDF.Core/Optimize/LinearizerGraph.cs: the object graph of a linearization: what the trailer
// reaches, who uses what, and the sections the objects fall into (Annex F.3). An object only one page reaches goes
// in that page's section; one that several pages reach goes in the shared section, or in the first page's when
// page one is among them. Page objects end a walk, so a link to another page does not pull it in.

extension Linearizer {
    func load(_ number: Int) -> PdfObject? { made[number] ?? document.get(number) }

    func collect() throws {
        nextMade = document.nextObjectNumber
        var pages: [PdfReference] = []
        var distinct: [PdfPage] = []
        for page in document.pages {
            if !pageNumbers.insert(page.reference.number).inserted { continue }
            pages.append(page.reference)
            distinct.append(page)
            pushDown(page)
        }
        if pages.isEmpty { throw InvalidOperationException("The document has no pages.") }
        if !treeIsClean(pages) { flatten(distinct) }

        root = intern(document.trailer["Root"])
        if root < 0 || !(items[root] is PdfDictionary) { throw PdfReadException.damaged("The catalog is missing.") }
        if document.info != nil { info = intern(document.trailer["Info"]) }
        follow()
        pageItem = pages.map { intern($0) }.filter { $0 >= 0 }
        follow()
        if let security = options.security {
            encrypt = items.count
            items.append(security.dictionary)
            oldNumbers.append(-1)
            children.append([])
        }
    }

    /// The index of the object `entry` names or is; -1 for nothing there.
    func intern(_ entry: PdfObject?) -> Int {
        if let reference = entry as? PdfReference {
            if let known = index[reference.number] { return known }
            guard let value = load(reference.number), !(value is PdfNull) else { return -1 }
            items.append(value)
            oldNumbers.append(reference.number)
            index[reference.number] = items.count - 1
            return items.count - 1
        }
        guard let direct = document.resolve(entry) else { return -1 }
        items.append(direct)
        oldNumbers.append(-1)
        return items.count - 1
    }

    private func follow() {
        while followed < items.count {
            let item = items[followed]
            var edges: [Int] = []
            let page = isPage(followed)
            if let stream = item as? PdfStream {
                visitEntries(stream.dictionary, true, page, &edges)
            } else if let dictionary = item as? PdfDictionary {
                visitEntries(dictionary, false, page, &edges)
            } else {
                visit(item, &edges)
            }
            children.append(edges)
            followed += 1
        }
    }

    /// A page keeps its /Parent out of the edges (the tree above is not the page's) and so does its
    /// thumbnail (F.3.3 sets thumbnails apart), and it lists /Contents first, so that the content
    /// streams come right after the page object.
    private func visitEntries(_ dictionary: PdfDictionary, _ stream: Bool, _ page: Bool, _ edges: inout [Int]) {
        if page {
            for (key, item) in dictionary.entries where key == "Contents" { visit(item, &edges) }
        }
        for (key, item) in dictionary.entries {
            if stream && key == "Length" { continue }
            if page && key == "Contents" { continue }
            // Interned all the same, so that the reference written for it has an object behind it.
            if page && (key == "Parent" || key == "Thumb") {
                var ignored: [Int] = []
                visit(item, &ignored)
            } else {
                visit(item, &edges)
            }
        }
    }

    private func visit(_ value: PdfObject, _ edges: inout [Int]) {
        switch value {
        case is PdfReference:
            let child = intern(value)
            if child >= 0 && !isPage(child) { edges.append(child) }
        case let array as PdfArray:
            for item in array.items { visit(item, &edges) }
        case let dictionary as PdfDictionary:
            for (_, item) in dictionary.entries { visit(item, &edges) }
        default:
            break
        }
    }

    func pageDictionary(_ item: Int) -> PdfDictionary {
        if let dictionary = items[item] as? PdfDictionary { return dictionary }
        return (items[item] as? PdfStream)?.dictionary ?? PdfDictionary()
    }

    private func isPage(_ item: Int) -> Bool {
        let old = oldNumbers[item]
        return old >= 0 && pageNumbers.contains(old)
    }

    private func pushDown(_ page: PdfPage) {
        let dictionary = page.dictionary
        var copy: PdfDictionary?
        var link = dictionary["Parent"]
        var depth = 0
        while depth < Self.maxDepth, let reference = link as? PdfReference {
            guard let node = document.get(reference.number) as? PdfDictionary else { break }
            for key in Self.inherited {
                guard let value = node[key], !(copy ?? dictionary).containsKey(key) else { continue }
                if copy == nil { copy = dictionary.copy() }
                copy?[key] = promote(value)
            }
            if Self.inherited.contains(where: { node.containsKey($0) }) {
                let stripped = (made[reference.number] as? PdfDictionary) ?? node.copy()
                for key in Self.inherited { stripped.remove(key) }
                made[reference.number] = stripped
            }
            link = node["Parent"]
            depth += 1
        }
        // Resources are required (7.7.3.3); a page that has none is given an empty set rather than left for a reader to repair.
        if !(copy ?? dictionary).containsKey("Resources") {
            if copy == nil { copy = dictionary.copy() }
            copy?["Resources"] = PdfDictionary()
        }
        if let copy { made[page.reference.number] = copy }
    }

    /// The tree under the catalog reaches exactly these pages, once each, with the right /Count in
    /// every node. The hint tables count pages the way a strict reader counts them from the tree.
    private func treeIsClean(_ pages: [PdfReference]) -> Bool {
        var leaves: [Int] = []
        var seen = Set<Int>()
        guard cleanNode(document.catalog["Pages"], 0, &leaves, &seen) != nil else { return false }
        return leaves == pages.map { $0.number }
    }

    /// The number of pages under a node, or nil when the node breaks the rules.
    private func cleanNode(_ link: PdfObject?, _ depth: Int, _ leaves: inout [Int], _ seen: inout Set<Int>) -> Int? {
        guard depth <= Self.maxDepth, let reference = link as? PdfReference, seen.insert(reference.number).inserted else { return nil }
        guard let node = document.get(reference.number) as? PdfDictionary else { return nil }
        if pageNumbers.contains(reference.number) {
            leaves.append(reference.number)
            return 1
        }
        guard let kids = node["Kids"] as? PdfArray else { return nil }
        var count = 0
        for kid in kids.items {
            guard let below = cleanNode(kid, depth + 1, &leaves, &seen) else { return nil }
            count += below
        }
        return document.integer(node, "Count") == count ? count : nil
    }

    /// One node over all the pages, for a tree that is not clean.
    private func flatten(_ pages: [PdfPage]) {
        guard let rootReference = document.catalog["Pages"] as? PdfReference else { return }
        let node = PdfDictionary()
        node.add("Type", PdfName("Pages"))
        node.add("Kids", PdfArray(pages.map { $0.reference }))
        node.add("Count", PdfNumber(pages.count))
        made[rootReference.number] = node
        for page in pages {
            let copy = (made[page.reference.number] as? PdfDictionary) ?? page.dictionary.copy()
            copy["Parent"] = rootReference
            made[page.reference.number] = copy
        }
    }

    /// A direct dictionary (the resources of a node) becomes one object, so that the pages inheriting it share it.
    private func promote(_ value: PdfObject) -> PdfObject {
        guard value is PdfDictionary else { return value }
        if let known = promoted[ObjectIdentifier(value)] { return known }
        let reference = PdfReference(nextMade, 0)
        nextMade += 1
        made[reference.number] = value
        promoted[ObjectIdentifier(value)] = reference
        return reference
    }

    func classify() throws {
        let count = pageItem.count
        guard count > 0 else { throw PdfReadException.damaged("The document has no pages.") }
        let catalog = pageDictionary(root)
        var mark = Array(repeating: 0, count: items.count)
        var token = 0

        // What the document-level keys reach belongs to the first section whichever page uses it: a
        // viewer reads that before anything else, so no page's hint entry lists it (the rule qpdf's check applies).
        var isOpen = Array(repeating: false, count: items.count)
        isOpen[root] = true
        for (key, value) in catalog.entries where Self.openKeys.contains(key) {
            var starts: [Int] = []
            references(value, &starts)
            for first in starts {
                token += 1
                try walk(first, &mark, token) { o in
                    if isOpen[o] { return false }
                    isOpen[o] = true
                    return true
                }
            }
        }

        // What a page's thumbnail reaches. An object only that page and its thumbnail use goes with the thumbnails.
        var thumbs = Array(repeating: false, count: items.count)
        for item in pageItem {
            var starts: [Int] = []
            references(pageDictionary(item)["Thumb"], &starts)
            for first in starts {
                token += 1
                try walk(first, &mark, token) { o in
                    if thumbs[o] { return false }
                    thumbs[o] = true
                    return true
                }
            }
        }

        var owner = Array(repeating: -1, count: items.count)
        var shared = Array(repeating: false, count: items.count)
        for p in 0..<count {
            token += 1
            try walk(pageItem[p], &mark, token) { o in
                if isOpen[o] { return false }
                if owner[o] < 0 {
                    owner[o] = p
                } else if owner[o] != p {
                    shared[o] = true
                }
                return true
            }
        }

        var placed = Array(repeating: false, count: items.count)
        pageObjects = Array(repeating: [], count: count)
        pageShared = Array(repeating: [], count: count)
        for p in 0..<count {
            token += 1
            try walk(pageItem[p], &mark, token) { o in
                if isOpen[o] { return false }
                if !shared[o] && thumbs[o] { return true }
                if p == 0 || !shared[o] {
                    placed[o] = true
                    if p == 0 { part6.append(o) } else { pageObjects[p].append(o) }
                } else {
                    if owner[o] != 0 && !placed[o] {
                        placed[o] = true
                        part8.append(o)
                    }
                    pageShared[p].append(o)
                }
                return true
            }
        }

        // The bookmarks are kept together, in the first page's section when the file opens on them (F.3.3).
        var bookmarks: [Int] = []
        references(catalog["Outlines"], &bookmarks)
        for first in bookmarks {
            token += 1
            try walk(first, &mark, token) { o in
                if isOpen[o] || placed[o] || owner[o] >= 0 { return false }
                placed[o] = true
                outlines.append(o)
                return true
            }
        }
        if document.name(catalog, "PageMode") == "UseOutlines" {
            part6 += outlines
        } else {
            part9 += outlines
        }
        // The first page's objects are the first section's list itself.
        pageObjects[0] = part6

        part4 = [root]
        if encrypt >= 0 { part4.append(encrypt) }
        for o in 0..<items.count where isOpen[o] && o != root { part4.append(o) }
        for o in part4 { placed[o] = true }
        for o in 0..<items.count where !placed[o] { part9.append(o) }
    }

    private func references(_ value: PdfObject?, _ into: inout [Int]) {
        switch value {
        case let reference as PdfReference:
            if let item = index[reference.number], !isPage(item) { into.append(item) }
        case let array as PdfArray:
            for entry in array.items { references(entry, &into) }
        case let dictionary as PdfDictionary:
            for (_, entry) in dictionary.entries { references(entry, &into) }
        default:
            break
        }
    }

    /// A depth-first walk in the order the objects are written; `visit` says whether to go on below an object.
    private func walk(_ first: Int, _ mark: inout [Int], _ token: Int, _ visit: (Int) -> Bool) throws {
        stack.removeAll(keepingCapacity: true)
        stack.append(first)
        while let o = stack.popLast() {
            if mark[o] == token { continue }
            mark[o] = token
            visits += 1
            if visits > Self.maxVisits { throw PdfReadException(.unsupported, "The file is too large to linearize.") }
            if !visit(o) { continue }
            let below = children[o]
            for i in stride(from: below.count - 1, through: 0, by: -1) where mark[below[i]] != token {
                stack.append(below[i])
            }
        }
    }
}
