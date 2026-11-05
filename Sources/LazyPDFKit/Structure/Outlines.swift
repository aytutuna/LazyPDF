import Foundation

// Twin of windows/LazyPDF.Core/Structure/Outlines.cs: bookmarks (ISO 32000-1 12.3.3).
//
// Two differences follow from the language. An item's parent is weak, so that a tree does not hold itself alive.
// A destination is a struct here, where the C# record is a reference whose identity says it was set: `write` takes
// the destination as changed when it differs from the one read, not when it is a different instance.

/// One bookmark. Change the properties freely and call `Outline.write`; the tree itself is changed through the `Outline`.
public final class OutlineItem {
    public var title = ""

    /// Where it goes: /Dest, or the destination of a GoTo action.
    public var destination: PdfDestination?

    /// The /A action, whatever it is.
    public var action: PdfAction?

    /// Text colour, each part 0 to 1; nil for the viewer's own.
    public var color: (r: Double, g: Double, b: Double)?

    public var bold = false
    public var italic = false

    /// The children show in the panel.
    public var isOpen = false

    public internal(set) weak var parent: OutlineItem?

    public var children: [OutlineItem] { childList }

    var childList: [OutlineItem] = []

    // What was read, so that a write leaves unknown keys, and a destination or action nobody touched, as they were.
    var reference: PdfReference?
    var source: PdfDictionary?
    var readDestination: PdfDestination?
    var readAction: PdfAction?

    public init() {}
}

/// The bookmark tree of a document. `read` takes a snapshot, the editing methods change it, `write` puts it back into
/// the document: items keep their objects and every key not listed here, removed ones are freed, /Count is worked out
/// again. A snapshot is stale once the document is saved through an edit session and reopened.
public final class Outline {
    private static let maxItems = 100_000
    private static let maxDepth = 64

    private var readNumbers = Set<Int>()

    private init() {
        root.isOpen = true
    }

    /// The top level; its children are the first row of bookmarks. Not written as an item.
    public let root = OutlineItem()

    public var items: [OutlineItem] { root.children }

    /// Reads /Outlines. A chain that loops, an item met twice, more than 100000 items or a tree deeper than 64 levels
    /// is cut off there.
    public static func read(_ document: PdfDocument) -> Outline {
        let outline = Outline()
        guard let top = document.dict(document.catalog, "Outlines") else { return outline }
        outline.root.source = top
        outline.root.reference = document.catalog["Outlines"] as? PdfReference
        let reader = Reader(document, outline)
        if let topReference = outline.root.reference { reader.seen.insert(topReference.number) }
        reader.fill(outline.root, top, 0)
        return outline
    }

    private final class Reader {
        let document: PdfDocument
        let outline: Outline
        let context: DestContext
        var seen = Set<Int>()
        var count = 0

        init(_ document: PdfDocument, _ outline: Outline) {
            self.document = document
            self.outline = outline
            context = DestContext(document)
        }

        func fill(_ parent: OutlineItem, _ dictionary: PdfDictionary, _ depth: Int) {
            if depth >= Outline.maxDepth { return }
            var link = dictionary["First"]
            while link != nil && count < Outline.maxItems {
                if let r = link as? PdfReference, !seen.insert(r.number).inserted { return }
                guard let node = document.resolve(link) as? PdfDictionary else { return }
                count += 1
                let item = readItem(node, link as? PdfReference)
                item.parent = parent
                parent.childList.append(item)
                if let known = item.reference { outline.readNumbers.insert(known.number) }
                fill(item, node, depth + 1)
                link = node["Next"]
            }
        }

        private func readItem(_ node: PdfDictionary, _ reference: PdfReference?) -> OutlineItem {
            let item = OutlineItem()
            item.title = PdfText.read(document, node, "Title") ?? ""
            item.reference = reference
            item.source = node
            item.isOpen = (document.integer(node, "Count") ?? 0) > 0
            if let color = document.array(node, "C"), color.items.count == 3 {
                let parts = color.items.map { document.resolve($0) as? PdfNumber }
                if let r = parts[0], let g = parts[1], let b = parts[2] {
                    item.color = (clamp(r.value), clamp(g.value), clamp(b.value))
                }
            }
            let flags = document.integer(node, "F") ?? 0
            item.italic = flags & 1 != 0
            item.bold = flags & 2 != 0
            item.readAction = PdfActions.read(document, node["A"], context)
            item.action = item.readAction
            item.readDestination = node.containsKey("Dest")
                ? PdfDestinations.parse(document, node["Dest"], context)
                : (item.readAction as? GoToAction)?.destination
            item.destination = item.readDestination
            return item
        }

        // Math.Clamp: a NaN stays a NaN.
        private func clamp(_ value: Double) -> Double {
            value < 0 ? 0 : (value > 1 ? 1 : value)
        }
    }

    /// Adds `item` under `parent` (the top level when nil) at `index`, the end by default.
    @discardableResult
    public func add(_ item: OutlineItem, _ parent: OutlineItem? = nil, _ index: Int = -1) throws -> OutlineItem {
        let parent = parent ?? root
        if item.parent != nil || Self.contains(item, parent) { throw ArgumentException("The item is already in a tree, or is the parent's ancestor.") }
        Self.insert(item, parent, index)
        return item
    }

    /// Takes the item, with its children, out of the tree. They are freed at the next write.
    public func remove(_ item: OutlineItem) {
        if let at = item.parent?.childList.firstIndex(where: { $0 === item }) { item.parent?.childList.remove(at: at) }
        item.parent = nil
    }

    /// Moves the item, with its children, under `parent` (the top level when nil) at `index`. The parent must not be
    /// the item or inside it.
    public func move(_ item: OutlineItem, _ parent: OutlineItem?, _ index: Int = -1) throws {
        let parent = parent ?? root
        if item.parent == nil { throw ArgumentException("The item is not in the tree.") }
        if Self.contains(item, parent) { throw ArgumentException("An item cannot move into itself.") }
        guard let old = item.parent, let at = old.childList.firstIndex(where: { $0 === item }) else { return }
        old.childList.remove(at: at)
        // Removing it from the same parent shifts the places after it.
        var index = index
        if old === parent && index > at { index -= 1 }
        Self.insert(item, parent, index)
    }

    private static func insert(_ item: OutlineItem, _ parent: OutlineItem, _ index: Int) {
        var index = index
        if index < 0 || index > parent.childList.count { index = parent.childList.count }
        parent.childList.insert(item, at: index)
        item.parent = parent
    }

    private static func contains(_ item: OutlineItem, _ candidate: OutlineItem) -> Bool {
        var at: OutlineItem? = candidate
        while let current = at {
            if current === item { return true }
            at = current.parent
        }
        return false
    }

    /// Stores the tree in the document. With no items /Outlines is taken out of the catalog and freed. An item whose
    /// destination refers to a page that is not there keeps the old one.
    public func write(_ document: PdfDocument) throws {
        var written = Set<Int>()
        if root.children.isEmpty {
            document.catalog.remove("Outlines")
        } else {
            let source = root.source ?? PdfDictionary()
            root.source = source
            if !Self.alive(document, root) { root.reference = try document.add(source) }
            source["Type"] = PdfName("Outlines")
            if let reference = root.reference {
                document.catalog["Outlines"] = reference
                written.insert(reference.number)
            }
            let visible = try Self.link(document, root, &written)
            Self.setCount(source, visible)
        }
        var stale = readNumbers
        if let r = root.reference { stale.insert(r.number) }
        for number in stale where !written.contains(number) {
            document.delete(number)
            readNumbers.remove(number)
        }
        readNumbers.formUnion(written)
    }

    // An item freed by an earlier write still holds its old reference.
    private static func alive(_ document: PdfDocument, _ item: OutlineItem) -> Bool {
        guard let reference = item.reference, let source = item.source else { return false }
        return document.resolve(reference) === source
    }

    // Writes the children of a parent and returns how many rows they show (12.3.3: the visible descendants, counting a
    // closed item's as none).
    private static func link(_ document: PdfDocument, _ parent: OutlineItem, _ written: inout Set<Int>) throws -> Int {
        let children = parent.children
        for child in children {
            let source = child.source ?? PdfDictionary()
            child.source = source
            if !alive(document, child) { child.reference = try document.add(source) }
            if let reference = child.reference { written.insert(reference.number) }
        }
        var visible = 0
        for (i, child) in children.enumerated() {
            let d = child.source ?? PdfDictionary()
            d["Title"] = PdfText.toObject(child.title)
            if let reference = parent.reference { d["Parent"] = reference }
            setLink(d, "Prev", i > 0 ? children[i - 1].reference : nil)
            setLink(d, "Next", i < children.count - 1 ? children[i + 1].reference : nil)
            try setTarget(document, child, d)
            setStyle(child, d)

            let below = try link(document, child, &written)
            setCount(d, child.isOpen ? below : -below)
            visible += 1 + (child.isOpen ? below : 0)
        }
        let holder = parent.source ?? PdfDictionary()
        setLink(holder, "First", children.first?.reference)
        setLink(holder, "Last", children.last?.reference)
        return visible
    }

    private static func setLink(_ d: PdfDictionary, _ key: String, _ target: PdfReference?) {
        if let target {
            d[key] = target
        } else {
            d.remove(key)
        }
    }

    private static func setCount(_ d: PdfDictionary, _ count: Int) {
        if count == 0 {
            d.remove("Count")
        } else {
            d["Count"] = PdfNumber(count)
        }
    }

    private static func setTarget(_ document: PdfDocument, _ item: OutlineItem, _ d: PdfDictionary) throws {
        if item.action !== item.readAction {
            d.remove("A")
            if let action = item.action {
                d["A"] = try PdfActions.toObject(document, action)
                d.remove("Dest")
            }
        }
        if item.destination != item.readDestination {
            if let destination = item.destination {
                if let value = PdfDestinations.toObject(document, destination) {
                    d["Dest"] = value
                    d.remove("A")
                }
            } else {
                d.remove("Dest")
                if item.action is GoToAction && item.action === item.readAction {
                    d.remove("A")
                    item.action = nil
                }
            }
        }
        item.readAction = item.action
        item.readDestination = item.destination
    }

    private static func setStyle(_ item: OutlineItem, _ d: PdfDictionary) {
        if let c = item.color {
            d["C"] = PdfArray([PdfNumber(c.r), PdfNumber(c.g), PdfNumber(c.b)])
        } else {
            d.remove("C")
        }
        let flags = (item.italic ? 1 : 0) | (item.bold ? 2 : 0)
        if flags == 0 {
            d.remove("F")
        } else {
            d["F"] = PdfNumber(flags)
        }
    }
}
