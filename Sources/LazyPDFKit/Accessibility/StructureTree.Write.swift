import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/StructureTree.Write.cs: stores the tree. Every element gets its dictionary
// written (keys this class does not know stay), the root's /K, /RoleMap, /ClassMap and /ParentTree are rebuilt from the
// elements, pages and objects that hold content get a /StructParents or /StructParent key where they have none or share
// one with another owner, /MarkInfo /Marked is set and removed elements are freed. A value that is already what would be
// written is left alone, so editing one element changes a few objects, not the whole tree.

private struct SlotKey: Hashable {
    let page: Int
    let stream: Int
}

private typealias ParentWork = (owner: PdfDictionary, name: String, element: StructElement, kid: StructKid)

extension StructureTree {
    // PDF integers stop at 2^31 - 1 (ISO 32000-1 Annex C), so a larger key is no key; it also keeps the next free number from overflowing.
    private static let maxKey = Int(Int32.max)
    private static let maxAnnotations = 5000

    /// Stores the tree. A tree whose parent tree arrays would run past four million slots is an `InvalidOperationException`.
    public func write(_ document: PdfDocument) throws {
        if isTruncated || parentSlots() > Self.maxParentSlots { throw InvalidOperationException(AccessibilityText.treeTooLarge) }
        let pages = document.pages
        if reference == nil { reference = try document.add(dictionary) }
        let all = elements
        for element in all where element.reference == nil { element.reference = try document.add(element.dictionary) }
        for element in all { writeElement(document, element, pages) }

        Self.put(dictionary, "K", Self.kids(rootList.compactMap { $0.reference }, dictionary["K"]))
        Self.put(dictionary, "RoleMap", roleMap.count == 0 ? nil : Self.mapOf(roleMap.entries.map { (key: $0.key, value: PdfName($0.value) as PdfObject) }))
        Self.put(dictionary, "ClassMap", classMap.count == 0 ? nil : Self.mapOf(classMap.entries))
        try writeParentTree(document, all, pages)

        for number in removed { document.delete(number) }
        removed.removeAll()

        let catalog = document.catalog
        let current = catalog["StructTreeRoot"] as? PdfReference
        if current == nil || current?.number != reference?.number { catalog["StructTreeRoot"] = reference }
        let info: PdfDictionary
        if let found = document.dict(catalog, "MarkInfo") {
            info = found
        } else {
            info = PdfDictionary()
            catalog["MarkInfo"] = info
        }
        if document.bool(info, "Marked") != true { info["Marked"] = PdfBoolean(true) }
    }

    // Each page's array in the parent tree runs up to its highest MCID, so a few far-off numbers would allocate a great deal.
    // A sequence number is a C# int; clamping keeps a caller's huge one from overflowing the sum.
    private func parentSlots() -> Int {
        var highest: [SlotKey: Int] = [:]
        for content in contents {
            let key = SlotKey(page: content.pageIndex, stream: content.stream?.number ?? 0)
            let mcid = Int(Int32(clamping: content.mcid))
            highest[key] = Swift.max(highest[key] ?? Int(Int32.min), mcid)
        }
        return highest.values.reduce(0) { $0 + $1 + 1 }
    }

    private func writeElement(_ document: PdfDocument, _ element: StructElement, _ pages: PdfPages) {
        let d = element.dictionary
        if d["Type"] == nil { d["Type"] = PdfName("StructElem") }
        Self.put(d, "S", element.type.isEmpty ? nil : PdfName(element.type))
        Self.put(d, "P", element.parent?.reference ?? reference)

        let page = element.pageIndex >= 0 ? element.pageIndex : (element.kidList.map(Self.pageOfKid).first { $0 >= 0 } ?? -1)
        Self.put(d, "Pg", page >= 0 && page < pages.count ? pages[page].reference : nil)
        Self.putText(document, d, "T", element.title)
        Self.putText(document, d, "Alt", element.alt)
        Self.putText(document, d, "Lang", element.lang)
        Self.putText(document, d, "ActualText", element.actualText)
        Self.putText(document, d, "ID", element.id)

        var items: [PdfObject] = []
        for kid in element.kidList {
            if let child = kid as? StructElement {
                if let reference = child.reference { items.append(reference) }
            } else if let content = kid as? StructContent {
                if content.stream == nil && content.pageIndex == page {
                    items.append(PdfNumber(content.mcid))
                    continue
                }
                let mcr = PdfDictionary()
                mcr["Type"] = PdfName("MCR")
                if content.pageIndex >= 0 && content.pageIndex < pages.count { mcr["Pg"] = pages[content.pageIndex].reference }
                mcr["MCID"] = PdfNumber(content.mcid)
                if let stream = content.stream { mcr["Stm"] = stream }
                if let owner = content.streamOwner { mcr["StmOwn"] = owner }
                items.append(mcr)
            } else if let target = kid as? StructObject {
                let objr = PdfDictionary()
                objr["Type"] = PdfName("OBJR")
                if target.pageIndex >= 0 && target.pageIndex < pages.count { objr["Pg"] = pages[target.pageIndex].reference }
                objr["Obj"] = target.target
                items.append(objr)
            }
        }
        Self.put(d, "K", Self.kids(items, d["K"]))
    }

    private static func pageOfKid(_ kid: StructKid) -> Int {
        if let content = kid as? StructContent { return content.pageIndex }
        if let object = kid as? StructObject { return object.pageIndex }
        return -1
    }

    private func writeParentTree(_ document: PdfDocument, _ all: [StructElement], _ pages: PdfPages) throws {
        var work: [ParentWork] = []
        for element in all {
            for kid in element.kidList {
                if let content = kid as? StructContent {
                    let owner: PdfDictionary?
                    if let stream = content.stream {
                        owner = (document.resolve(stream) as? PdfStream)?.dictionary
                    } else {
                        owner = content.pageIndex >= 0 && content.pageIndex < pages.count ? pages[content.pageIndex].dictionary : nil
                    }
                    if let owner { work.append((owner, "StructParents", element, kid)) }
                } else if let target = kid as? StructObject {
                    let resolved = document.resolve(target.target)
                    let owner = (resolved as? PdfStream)?.dictionary ?? resolved as? PdfDictionary
                    if let owner { work.append((owner, "StructParent", element, kid)) }
                }
            }
        }

        var used = Set<Int>()
        for item in work {
            if let existingKey = Self.keyOf(document, item.owner, item.name) { used.insert(existingKey) }
        }
        for page in pages {
            if let pageKey = Self.keyOf(document, page.dictionary, "StructParents") { used.insert(pageKey) }
        }
        let strays = Self.strays(document, work.map { $0.owner } + pages.map { $0.dictionary })
        for stray in strays { used.insert(stray.key) }
        var next = Swift.max(Swift.min(document.integer(dictionary, "ParentTreeNextKey") ?? 0, Self.maxKey), (used.max() ?? -1) + 1)

        // A key stands for one owner; a later owner that carries the same number (pages merged by another tool) gets a new one.
        var owners: [Int: PdfDictionary] = [:]
        var assigned: [(key: Int, element: StructElement, kid: StructKid)] = []
        for item in work.filter({ !($0.kid is StructObject) }) + work.filter({ $0.kid is StructObject }) {
            var key = Self.keyOf(document, item.owner, item.name) ?? -1
            if key < 0 || (owners[key].map { $0 !== item.owner } ?? false) {
                key = next
                next += 1
                item.owner[item.name] = PdfNumber(key)
            }
            owners[key] = item.owner
            assigned.append((key, item.element, item.kid))
        }

        // The parent tree is rebuilt from the elements above, so a number a form or annotation outside them still carries would now lead to another owner's element.
        for stray in strays where owners[stray.key] != nil { stray.owner.remove(stray.name) }

        // A page without tagged content has no use for a key, and one that another owner now holds would point its numbers at that owner's elements.
        for page in pages {
            if let pageKey = Self.keyOf(document, page.dictionary, "StructParents"),
               let holder = owners[pageKey], holder !== page.dictionary {
                page.dictionary.remove("StructParents")
            }
        }

        var entries: [Int: PdfObject] = [:]
        var arrays: [Int: [PdfObject]] = [:]
        for item in assigned {
            guard let reference = item.element.reference else { continue }
            if let content = item.kid as? StructContent {
                while arrays[item.key, default: []].count <= content.mcid { arrays[item.key, default: []].append(PdfNull.instance) }
                arrays[item.key, default: []][content.mcid] = reference
            } else {
                entries[item.key] = reference
            }
        }
        for (key, list) in arrays { entries[key] = PdfArray(list) }

        let existing = PdfNumberTree.read(document, dictionary["ParentTree"])
        let same = existing.count == entries.count && existing.allSatisfy { entry in
            guard let value = entries[entry.key], let stored = document.resolve(entry.value) else { return false }
            return value.description == stored.description
        }
        if !same {
            let sorted = entries.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
            let root = try PdfNumberTree.write(document, document.dict(dictionary, "ParentTree"), sorted)
            if dictionary["ParentTree"] == nil { dictionary["ParentTree"] = try document.add(root) }
        }
        let highest = entries.keys.max() ?? -1
        Self.put(dictionary, "ParentTreeNextKey", PdfNumber(Swift.max(next, highest + 1)))
    }

    private static func keyOf(_ document: PdfDocument, _ owner: PdfDictionary, _ name: String) -> Int? {
        guard let key = document.integer(owner, name), key >= 0, key <= maxKey else { return nil }
        return key
    }

    // Every object, and the annotations a page holds as direct dictionaries, which no object number leads to.
    private static func strays(_ document: PdfDocument, _ known: [PdfDictionary]) -> [(owner: PdfDictionary, name: String, key: Int)] {
        let skip = Set(known.map { ObjectIdentifier($0) })
        var found: [(owner: PdfDictionary, name: String, key: Int)] = []
        var candidates: [PdfDictionary] = []
        for number in document.objectNumbers {
            if let stream = document.get(number) as? PdfStream {
                candidates.append(stream.dictionary)
            } else if let plain = document.get(number) as? PdfDictionary {
                candidates.append(plain)
            }
        }
        for page in document.pages {
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            candidates.append(contentsOf: annots.items.prefix(maxAnnotations).compactMap { $0 as? PdfDictionary })
        }
        for d in candidates where !skip.contains(ObjectIdentifier(d)) {
            for name in ["StructParents", "StructParent"] {
                if let key = keyOf(document, d, name) { found.append((d, name, key)) }
            }
        }
        return found
    }

    private static func kids(_ items: [PdfObject], _ current: PdfObject?) -> PdfObject? {
        if items.isEmpty { return nil }
        if items.count == 1 && !(current is PdfArray) { return items[0] }
        return PdfArray(items)
    }

    private static func mapOf(_ map: [(key: String, value: PdfObject)]) -> PdfDictionary {
        let d = PdfDictionary()
        for entry in map { d[entry.key] = entry.value }
        return d
    }

    private static func put(_ d: PdfDictionary, _ key: String, _ value: PdfObject?) {
        let current = d[key]
        if let value {
            if current == nil || current?.description != value.description { d[key] = value }
        } else if current != nil {
            d.remove(key)
        }
    }

    private static func putText(_ document: PdfDocument, _ d: PdfDictionary, _ key: String, _ value: String?) {
        guard let value, !value.isEmpty else {
            d.remove(key)
            return
        }
        if PdfText.read(document, d, key) != value { d[key] = PdfText.toObject(value) }
    }
}
