import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionObjects.cs: the objects of the file as the redaction sees them: what an
// object leads to, and the last sweep that empties what a redacted page reached and nothing painted reaches. Emptying is done
// where the object is, so whoever still names it (structure elements, private data, thumbnails, page-level keys) holds an
// empty one.
//
// The C# keeps sets of objects by reference (ReferenceEqualityComparer). Here they are sets of ObjectIdentifier that also hold
// the objects, so that an identity cannot be reused by a new object while the set is alive.

enum RedactionObjects {
    /// The keys by which a stream is part of what is painted, the keys whose dictionaries hold such streams under names of
    /// their own, and the keys that hold pictures and forms. Every other value is followed, but a stream only through one of
    /// these: an object that something merely names does not stay for it.
    struct Reading {
        let streams: Set<String>
        let wide: Set<String>
        let objects: Set<String>

        init(_ streams: [String], _ wide: [String], _ objects: [String]) {
            self.streams = Set(streams)
            self.wide = Set(wide)
            self.objects = Set(objects)
        }
    }

    // The masks of a picture are read through the picture, the one place where /SMask and /Mask mean a stream.
    private static let paintKeys = [
        "ColorSpace", "CS", "Alternate", "Function", "Functions", "Process", "Colorants", "Shading", "TR", "TR2", "BG", "BG2", "UCR", "UCR2",
        "HT", "TransferFunction", "FontFile", "FontFile2", "FontFile3", "ToUnicode", "UseCMap", "CIDToGIDMap", "CIDSet", "Encoding", "CharProcs",
        "DestOutputProfile", "JBIG2Globals",
    ]

    private static let masks = ["SMask", "Mask"]

    /// What a page paints through: its pictures, fonts, colour spaces and the functions of its states.
    static let painting = Reading(paintKeys, ["CharProcs", "Colorants"], [])

    /// The same, and an annotation's own appearances, which the walk enters as forms.
    static let annotating = Reading(paintKeys + ["V", "DV", "RC"], ["CharProcs", "Colorants"], [])

    // Everything a page lists, for a page that cannot be followed to see what it paints.
    private static let listKeys = ["Contents", "XObject", "Pattern", "Shading", "AP", "N", "D", "R"]

    /// All a page could paint: every entry of its resource lists and every appearance.
    static let listing = Reading(paintKeys + listKeys, ["CharProcs", "Colorants", "XObject", "Pattern", "Shading", "N", "D", "R"], listKeys)

    private static let layers = Reading([], [], [])

    private struct Item {
        var value: PdfObject?
        var stream: Bool
        var wide: Bool
        var listed: Bool
        var objects: Bool
    }

    /// Objects by identity.
    struct Identities {
        private var ids = Set<ObjectIdentifier>()
        private var held: [PdfObject] = []

        var isEmpty: Bool { ids.isEmpty }

        func contains(_ object: PdfObject) -> Bool { ids.contains(ObjectIdentifier(object)) }

        @discardableResult
        mutating func insert(_ object: PdfObject) -> Bool {
            if !ids.insert(ObjectIdentifier(object)).inserted { return false }
            held.append(object)
            return true
        }
    }

    // Found once, before any page is rewritten, so that the content streams are the ones the pages named.
    private final class Skeleton {
        let tree: Identities
        let contents: Identities

        init(_ tree: Identities, _ contents: Identities) {
            self.tree = tree
            self.contents = contents
        }
    }

    private final class Cached {
        weak var document: PdfDocument?
        let skeleton: Skeleton

        init(_ document: PdfDocument, _ skeleton: Skeleton) {
            self.document = document
            self.skeleton = skeleton
        }
    }

    private static let lock = NSLock()
    private static var skeletons: [ObjectIdentifier: Cached] = [:]

    // What ConditionalWeakTable.GetValue is: the first call for a document finds it, and it stays as long as the document does.
    private static func skeleton(_ document: PdfDocument) -> Skeleton {
        let key = ObjectIdentifier(document)
        lock.lock()
        if let known = skeletons[key], known.document === document {
            lock.unlock()
            return known.skeleton
        }
        lock.unlock()
        let found = find(document)
        lock.lock()
        defer { lock.unlock() }
        if let known = skeletons[key], known.document === document { return known.skeleton }
        skeletons = skeletons.filter { $0.value.document != nil }
        skeletons[key] = Cached(document, found)
        return found
    }

    /// Adds the numbers of every object `root` leads to. Pages, page tree nodes and the catalog are not part of what a page
    /// holds, whatever names them (destinations, annotations, tags), unless a resource list is one. `apart` are keys of the
    /// root itself that are left out.
    static func collect(_ document: PdfDocument, _ root: PdfObject?, _ into: inout Set<Int>, _ apart: [String] = []) {
        follow(document, root, &into, nil, true, apart)
    }

    /// As `collect`, but a stream is followed only by the keys of `reading`, and the root is not one: it is a dictionary, an
    /// array or a name that something paints through.
    static func painted(_ document: PdfDocument, _ root: PdfObject?, _ into: inout Set<Int>, _ reading: Reading, _ apart: [String] = []) {
        follow(document, root, &into, reading, false, apart)
    }

    /// As `painted`, for a root that is painted itself: a picture, a form, a pattern cell or content.
    static func paintedStream(_ document: PdfDocument, _ root: PdfObject?, _ into: inout Set<Int>, _ reading: Reading, _ apart: [String] = []) {
        follow(document, root, &into, reading, true, apart)
    }

    /// A picture, form, pattern cell, packet of metadata, attachment or content of a page: nothing a font or a colour is made of.
    static func barred(_ document: PdfDocument, _ stream: PdfStream) -> Bool {
        let subtype = document.name(stream.dictionary, "Subtype"), type = document.name(stream.dictionary, "Type")
        return subtype == "Image" || subtype == "Form" || subtype == "XML" || type == "XObject" || type == "Metadata" || type == "EmbeddedFile"
            || stream.dictionary.containsKey("PatternType") || skeleton(document).contents.contains(stream)
    }

    static func isImage(_ document: PdfDocument, _ stream: PdfStream) -> Bool { document.name(stream.dictionary, "Subtype") == "Image" }

    /// Whether the object is the catalog, a page tree node or a page.
    static func inTree(_ document: PdfDocument, _ value: PdfObject?) -> Bool {
        guard let resolved = document.resolve(value) else { return false }
        return skeleton(document).tree.contains(resolved)
    }

    private static func follow(_ document: PdfDocument, _ root: PdfObject?, _ into: inout Set<Int>, _ reading: Reading?, _ stream: Bool, _ apart: [String]) {
        let shape = Self.skeleton(document)
        var pending: [Item] = []
        var entered = Identities()
        func visit(_ first: Item, _ skipped: [String]) {
            var item = first
            var value = item.value
            while let reference = value as? PdfReference {
                guard let target = document.get(reference.number) else { return }
                if shape.tree.contains(target) {
                    // A tree node named as a resource list is a list, not structure: what it holds is followed and the node itself is not swept.
                    if !item.listed || !entered.insert(target) { return }
                    value = target
                    item.listed = false
                    break
                }
                if let held = target as? PdfStream, !item.stream || (reading != nil && !item.objects && barred(document, held)) { return }
                if !into.insert(reference.number).inserted { return }
                value = target
            }
            switch value {
            case let held as PdfStream:
                var inner = item
                inner.value = held.dictionary
                inner.stream = false
                inner.wide = false
                visit(inner, skipped)
                if reading == nil || !isImage(document, held) { break }
                for key in masks {
                    if let mask = held.dictionary[key], let picture = document.resolve(mask) as? PdfStream, isImage(document, picture) {
                        pending.append(Item(value: mask, stream: true, wide: false, listed: false, objects: true))
                    }
                }
            case let dictionary as PdfDictionary:
                for (key, member) in dictionary.entries {
                    if skipped.contains(key) { continue }
                    let grants = item.wide || reading == nil || (reading?.streams.contains(key) ?? false)
                    let wide = !item.wide && (reading?.wide.contains(key) ?? false)
                    let objects = (item.wide && item.objects) || (reading?.objects.contains(key) ?? false)
                    pending.append(Item(value: member, stream: grants, wide: wide, listed: item.listed || key == "Resources", objects: objects))
                }
            case let array as PdfArray:
                for member in array.items {
                    var next = item
                    next.value = member
                    next.wide = false
                    pending.append(next)
                }
            default:
                break
            }
        }
        visit(Item(value: root, stream: stream, wide: false, listed: false, objects: stream), apart)
        while let next = pending.popLast() { visit(next, []) }
    }

    // The catalog, the page tree and every page, by their place in the tree and not by a /Type that anything can claim.
    private static func find(_ d: PdfDocument) -> Skeleton {
        let maxDepth = 256
        var nodes = Identities()
        nodes.insert(d.catalog)
        var stack: [(node: PdfObject?, depth: Int)] = [(d.catalog["Pages"], 0)]
        while let (node, depth) = stack.popLast() {
            guard let dictionary = d.resolve(node) as? PdfDictionary, depth <= maxDepth, nodes.insert(dictionary) else { continue }
            if let kids = d.resolve(dictionary["Kids"]) as? PdfArray {
                for kid in kids.items { stack.append((kid, depth + 1)) }
            }
        }
        var contents = Identities()
        for page in d.pages {
            nodes.insert(page.dictionary)
            for stream in RedactionResources.contents(d, page) { contents.insert(stream) }
        }
        return Skeleton(nodes, contents)
    }

    /// Empties every object in `reached` that is not in `painted`. The layers and the output intents stay: pages that were not
    /// redacted depend on them.
    static func sweep(_ document: PdfDocument, _ reached: Set<Int>, _ painted: inout Set<Int>) {
        Self.painted(document, document.catalog["OCProperties"], &painted, layers)
        Self.painted(document, document.catalog["OutputIntents"], &painted, Self.painting)
        for number in reached.sorted() where !painted.contains(number) {
            switch document.get(number) {
            case let stream as PdfStream:
                stream.data = []
                clear(stream.dictionary)
            case let dictionary as PdfDictionary:
                clear(dictionary)
            case let array as PdfArray:
                array.items.removeAll()
            case nil, is PdfNull:
                break
            default:
                document.set(number, PdfNull.instance)
            }
        }
    }

    private static func clear(_ dictionary: PdfDictionary) {
        for (key, _) in dictionary.entries { dictionary.remove(key) }
    }
}
