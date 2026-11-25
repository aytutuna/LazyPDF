import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageImporter.cs: copies pages from one document into another. When both are the same
// document the copies share everything but their annotations and form fields. One importer is one import: its map from
// source objects to copies lives as long as it does, so a font or image used by many pages is copied once. References are
// followed through a work queue, not by recursion, so a chain of a million objects costs no stack and a cycle ends where it
// closes.
//
// The C# `Import` is `importPages` here (`import` is a Swift keyword). The stored properties of the C# partial class are
// all declared below; the extensions in the other PageImporter files only add methods.

/// A dictionary that remembers the order its keys came in; the C# Dictionary is enumerated into output in places.
struct OrderedMap<Value> {
    private var order: [Int] = []
    private var values: [Int: Value] = [:]

    subscript(key: Int) -> Value? {
        get { values[key] }
        set {
            guard let newValue else { return }
            if values.updateValue(newValue, forKey: key) == nil { order.append(key) }
        }
    }

    var entries: [(key: Int, value: Value)] {
        order.compactMap { key in values[key].map { (key: key, value: $0) } }
    }

    mutating func removeAll() {
        order.removeAll()
        values.removeAll()
    }
}

final class PageImporter {
    private static let pageOnly = ["Type", "Parent", "B", "StructParents", "Annots", "Resources", "MediaBox", "CropBox", "Rotate"]

    let source: PdfDocument
    let target: PdfDocument
    let same: Bool
    let sourcePages: Set<Int>
    var map = OrderedMap<PdfReference>()
    var newPages: [Int: PdfReference] = [:]
    var pending: [(source: Int, target: Int)] = []
    var droppedNumbers = Set<Int>()
    var skip = Set<Int>()
    var cut = Set<ObjectIdentifier>()

    /// Whether the pages and annotations keep their keys into the tag tree, which `copyTree` then copies.
    var keepTags = false

    /// How many objects the source lists that were referenced by what came across but could not be read, so they are left out.
    var dropped: Int { droppedNumbers.count }
    var taggedCopies = OrderedMap<PdfReference>()

    var layersAdded = Set<Int>()

    var actionNodes = 0
    var local = OrderedMap<PdfReference>()
    var fields: [Int: (ref: PdfReference, kids: PdfArray)] = [:]
    var names: DestContext?
    var rootNames: Set<String>?
    var formMerged = false
    var fieldActions: [(original: PdfDictionary, made: PdfDictionary)] = []
    var fontRenames: [String: String] = [:]
    var copies: [Int: [PdfReference]] = [:]
    var groups: [ObjectIdentifier: FieldCopy] = [:]
    var groupOrder: [FieldCopy] = []

    // A field above widgets as copied: which of the source's kids came across, by position.
    final class FieldCopy {
        let original: PdfDictionary
        let made: PdfDictionary
        var positions: [Int] = []

        init(_ original: PdfDictionary, _ made: PdfDictionary) {
            self.original = original
            self.made = made
        }
    }

    init(_ source: PdfDocument, _ target: PdfDocument) {
        self.source = source
        self.target = target
        same = source === target
        sourcePages = Set(source.pages.map { $0.reference.number })
    }

    /// Copies the pages at these source indexes (repeats give separate copies); the new pages belong to no tree yet.
    func importPages(_ indexes: [Int]) throws -> [PdfReference] {
        let pages = source.pages
        // A field made by an earlier import is not this one's: the copies of a document listed twice each get their own.
        fields.removeAll()
        var made: [(page: PdfPage, ref: PdfReference, dict: PdfDictionary)] = []
        for index in indexes {
            try Task.checkCancellation()
            precondition(index >= 0 && index < pages.count, "There is no page \(index &+ 1).")
            let dict = PdfDictionary()
            let reference = try target.add(dict)
            // Links between pages that come across all go to the new pages; a repeated page is reached at its first copy.
            if !same && newPages[pages[index].reference.number] == nil { newPages[pages[index].reference.number] = reference }
            made.append((pages[index], reference, dict))
        }
        var seen = Set<Int>()
        for (page, reference, dict) in made {
            try Task.checkCancellation()
            if !seen.insert(page.reference.number).inserted { fields.removeAll() }
            try fillPage(page, reference, dict)
        }
        try trimGroups()
        carryOrder()
        try drain()
        mergeLayers()
        return made.map { $0.ref }
    }

    /// A copy of a value from the source, its references copied with it.
    func copyValue(_ value: PdfObject) throws -> PdfObject {
        let made = try copy(value)
        try drain()
        return made
    }

    /// A copy of the source's structure tree in which a page that did not come across is `ghost`, and an element with
    /// nothing left on the pages taken is not copied. The parent and ID trees are left to the caller.
    func copyTree(_ root: PdfObject, _ ghost: PdfReference) throws -> PdfObject {
        let taken = Set(sourcePages.filter { newPages[$0] != nil })
        skip.formUnion(TagCut.dead(source, root, taken, sourcePages))
        if let top = source.resolve(root) as? PdfDictionary {
            for key in ["ParentTree", "IDTree"] {
                if let tree = top[key] { cut.insert(ObjectIdentifier(tree)) }
            }
        }
        let added = sourcePages.sorted().filter { newPages[$0] == nil }
        for number in added { newPages[number] = ghost }
        for entry in taggedCopies.entries where map[entry.key] == nil { map[entry.key] = entry.value }
        // An annotation the importer dropped must not come back through the tree as a copy that is on no page.
        for page in source.pages {
            guard let annots = source.resolve(page.dictionary["Annots"]) as? PdfArray else { continue }
            for item in annots.items {
                if let r = item as? PdfReference, taggedCopies[r.number] == nil { skip.insert(r.number) }
            }
        }
        let made = try copyValue(root)
        for number in added { newPages[number] = nil }
        cut.removeAll()
        return made
    }

    private func fillPage(_ page: PdfPage, _ reference: PdfReference, _ dict: PdfDictionary) throws {
        dict["Type"] = PdfName("Page")
        // Written out even when equal to the default, so that nothing is inherited from the new tree (7.7.3.4).
        dict["MediaBox"] = page.mediaBox.toArray()
        dict["CropBox"] = page.cropBox.toArray()
        dict["Rotate"] = PdfNumber(page.rotate)
        var resources: PdfObject = PdfDictionary()
        if let found = inherited(page, "Resources") {
            resources = found
        } else if let own = page.resources {
            resources = own
        }
        dict["Resources"] = try copy(try pruned(page, resources))
        for (key, value) in page.dictionary.entries {
            if (Self.pageOnly.contains(key) && !(keepTags && key == "StructParents")) || page.dictionary[key] !== value { continue }
            let made = try copy(value)
            if !(made is PdfNull) { dict.add(key, made) }
        }
        try copyAnnotations(page, reference, dict)
    }

    private func inherited(_ page: PdfPage, _ key: String) -> PdfObject? {
        var node: PdfDictionary? = page.dictionary
        var depth = 0
        while let current = node, depth < 64 {
            if let value = current[key], !(value is PdfNull) { return value }
            node = source.dict(current, "Parent")
            depth += 1
        }
        return nil
    }

    func copy(_ value: PdfObject) throws -> PdfObject {
        switch value {
        case let reference as PdfReference:
            if same { return reference }
            return try copyReference(reference)
        case let array as PdfArray: return PdfArray(try array.items.map { try copy($0) })
        case let dictionary as PdfDictionary: return try copyDictionary(dictionary)
        case let text as PdfString: return PdfString(bytes: text.bytes, isHex: text.isHex)
        default: return value
        }
    }

    func copyDictionary(_ original: PdfDictionary) throws -> PdfDictionary {
        let made = PdfDictionary()
        for (key, value) in original.entries {
            if original[key] !== value || cut.contains(ObjectIdentifier(value)) { continue }
            let item = try copy(value)
            if !(item is PdfNull) { made.add(key, item) }
        }
        return made
    }

    private func copyReference(_ reference: PdfReference) throws -> PdfObject {
        if skip.contains(reference.number) { return PdfNull.instance }
        if let done = map[reference.number] ?? newPages[reference.number] { return done }
        // A page that did not come across, the tree above it and the catalog would drag the whole file in.
        guard let value = source.get(reference.number), !(value is PdfNull) else {
            noteUnreadable(reference)
            return PdfNull.instance
        }
        guard !sourcePages.contains(reference.number), !isStructure(value) else { return PdfNull.instance }
        let made = try target.add(PdfNull.instance)
        map[reference.number] = made
        pending.append((reference.number, made.number))
        return made
    }

    // The source's object for a value, counting a reference it lists but cannot read among the dropped.
    func read(_ value: PdfObject?) -> PdfObject? {
        let found = source.resolve(value)
        if found == nil, let reference = value as? PdfReference { noteUnreadable(reference) }
        return found
    }

    private func noteUnreadable(_ reference: PdfReference) {
        if let listed = source.entries[reference.number], listed.kind == .inUse || listed.kind == .compressed { droppedNumbers.insert(reference.number) }
    }

    private func isStructure(_ value: PdfObject) -> Bool {
        guard let dictionary = value as? PdfDictionary, let type = source.name(dictionary, "Type") else { return false }
        return type == "Page" || type == "Pages" || type == "Catalog"
    }

    private func drain() throws {
        var next = 0
        while next < pending.count {
            let item = pending[next]
            next += 1
            guard let value = source.get(item.source) else { continue }
            if let stream = value as? PdfStream {
                target.set(item.target, try copyStream(stream))
            } else {
                target.set(item.target, try copy(value))
            }
        }
        pending.removeAll()
    }

    private func copyStream(_ stream: PdfStream) throws -> PdfStream {
        // A form's own resources are pruned like a page's, so that a shared set does not carry the whole file along.
        var own: PdfObject?
        if !same && source.name(stream.dictionary, "Subtype") == "Form", let found = stream.dictionary["Resources"],
           source.resolve(found) is PdfDictionary {
            own = found
        }
        var shell = stream.dictionary
        if own != nil {
            shell = stream.dictionary.copy()
            shell.remove("Resources")
        }
        let dict = try copyDictionary(shell)
        if let own { dict["Resources"] = try copy(try prunedForm(stream, own)) }
        dict.remove("Length")
        // The data comes out of the source decrypted; its Crypt stage has been carried out and does not go along.
        let (filter, parameters, crypt) = source.decodeSpec(stream)
        if crypt {
            dict.remove("Filter")
            dict.remove("DecodeParms")
            if let filter { dict["Filter"] = try copy(filter) }
            if let parameters, !(parameters is PdfNull) { dict["DecodeParms"] = try copy(parameters) }
        }
        return PdfStream(dict, data: source.rawData(stream))
    }
}
