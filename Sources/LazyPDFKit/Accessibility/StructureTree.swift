import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/StructureTree.cs: the logical structure of a document (ISO 32000-1 14.7,
// 14.8): the elements under /StructTreeRoot, the role and class maps and the parent tree. A snapshot, as `Outline` is:
// edit it, then `write`; it is stale once the session has committed and reopened the document. Reading is tolerant
// (loops, junk kids, missing /S) and capped; a tree past the caps is read as far as it goes and `isTruncated` is set,
// after which it cannot be written.
//
// The C# class is partial; the write part is an extension in StructureTree.Write.swift, so the state is declared here and
// is internal. `Add` and `Move` throw `ArgumentException`, which a drag in the editor can cause. RoleMap and ClassMap are
// `OrderedNames`: `write` puts them into the file in the order the entries were added, which a Swift Dictionary would not keep.

/// A dictionary with string keys that remembers the order its keys came in.
public struct OrderedNames<Value> {
    private var order: [String] = []
    private var values: [String: Value] = [:]

    public init() {}

    public var count: Int { order.count }

    public var entries: [(key: String, value: Value)] {
        order.compactMap { key in values[key].map { (key: key, value: $0) } }
    }

    public subscript(key: String) -> Value? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { order.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                order.removeAll { $0 == key }
            }
        }
    }

    public func containsKey(_ key: String) -> Bool { values[key] != nil }
}

public final class StructureTree {
    private static let maxDepth = 128
    private static let maxNodes = 1_000_000
    static let maxMcid = 1_000_000
    static let maxParentSlots = 4_000_000

    private static let standard: Set<String> = [
        "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct", "Private",
        "P", "H", "L", "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot", "Span", "Quote", "Note",
        "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP", "Figure",
        "Formula", "Form",
    ]

    let document: PdfDocument
    var rootList: [StructElement] = []
    var byNumber: [Int: StructElement] = [:]
    var removed = Set<Int>()
    private var pageByNumber: [Int: Int] = [:]
    private var nodes = 0

    private init(_ document: PdfDocument, _ root: PdfDictionary, _ reference: PdfReference?) {
        self.document = document
        dictionary = root
        self.reference = reference
        let pages = document.pages
        for i in 0..<pages.count where pageByNumber[pages[i].reference.number] == nil {
            pageByNumber[pages[i].reference.number] = i
        }
    }

    /// The /StructTreeRoot dictionary, live.
    public let dictionary: PdfDictionary

    public internal(set) var reference: PdfReference?

    /// The elements directly under the root, normally one /Document.
    public var roots: [StructElement] { rootList }

    /// Custom type to the type it stands for (14.8.3); change it and write.
    public var roleMap = OrderedNames<String>()

    /// Class name to its attribute object (14.7.5.2), as stored.
    public var classMap = OrderedNames<PdfObject>()

    /// The parent tree as stored: key to an array of elements by MCID, or to one element for an object. Values are as in the file.
    public private(set) var parentTree: [(key: Int, value: PdfObject)] = []

    /// The tree has more nodes or levels than the reader takes; it cannot be written.
    public private(set) var isTruncated = false

    /// Every element, parents before children.
    public var elements: [StructElement] {
        var found: [StructElement] = []
        var stack = Array(rootList.reversed())
        while let element = stack.popLast() {
            found.append(element)
            for kid in element.kidList.reversed() {
                if let child = kid as? StructElement { stack.append(child) }
            }
        }
        return found
    }

    public var contents: [StructContent] {
        elements.flatMap { $0.kidList.compactMap { $0 as? StructContent } }
    }

    /// The tree of a document, or nil when it has no /StructTreeRoot.
    public static func read(_ document: PdfDocument) -> StructureTree? {
        guard let root = document.dict(document.catalog, "StructTreeRoot") else { return nil }
        let tree = StructureTree(document, root, document.catalog["StructTreeRoot"] as? PdfReference)
        tree.readAll()
        return tree
    }

    /// An empty tree; `write` adds it to the document.
    public static func create(_ document: PdfDocument) -> StructureTree {
        let root = PdfDictionary()
        root["Type"] = PdfName("StructTreeRoot")
        return StructureTree(document, root, nil)
    }

    public static func isStandard(_ type: String) -> Bool {
        if standard.contains(type) { return true }
        let units = Array(type.utf16)
        return units.count >= 2 && units.count <= 4 && units[0] == 0x48
            && units.dropFirst().allSatisfy { $0 >= 0x30 && $0 <= 0x39 } && units[1] != 0x30
    }

    /// The standard type `type` stands for through the role map (cycles and chains past 16 stop where they are).
    public func standardType(_ type: String) -> String {
        var type = type
        var i = 0
        while i < 16 && !Self.isStandard(type) {
            guard let next = roleMap[type], next != type else { break }
            type = next
            i += 1
        }
        return type
    }

    /// The element the parent tree names for a page's (or form's, or object's) key, and the sequence with that /MCID; for an object pass -1.
    public func elementFor(_ key: Int, _ mcid: Int) -> StructElement? {
        for entry in parentTree where entry.key == key {
            let resolved = document.resolve(entry.value)
            let target: PdfObject?
            if mcid >= 0, let array = resolved as? PdfArray {
                target = mcid < array.items.count ? array.items[mcid] : nil
            } else {
                target = entry.value
            }
            guard let reference = target as? PdfReference else { return nil }
            return byNumber[reference.number]
        }
        return nil
    }

    /// Puts `kid` under `parent` (nil: the root) at `index`, -1 for the end. A kid that is in the tree already is an `ArgumentException`; use `move`.
    public func add(_ parent: StructElement?, _ kid: StructKid, _ index: Int = -1) throws {
        if kid.parent != nil || rootList.contains(where: { $0 === kid }) { throw ArgumentException(AccessibilityText.alreadyInTree) }
        if parent == nil && !(kid is StructElement) { throw ArgumentException(AccessibilityText.rootNeedsElement) }
        var p = parent
        while let up = p {
            if up === kid { throw ArgumentException(AccessibilityText.intoItself) }
            p = up.parent
        }
        if let element = kid as? StructElement { unmark(element) }
        insert(parent, kid, index)
    }

    /// Takes `kid` and what is under it out; the objects of the elements are freed at the next `write`.
    public func remove(_ kid: StructKid) {
        detach(kid)
        guard let element = kid as? StructElement else { return }
        var stack = [element]
        while let e = stack.popLast() {
            if let reference = e.reference { removed.insert(reference.number) }
            stack.append(contentsOf: e.children)
        }
    }

    /// Puts `kid` under `parent` (nil: the root) at `index` counted after it left its old place; -1 is the end. Reordering is a move inside one parent.
    public func move(_ kid: StructKid, _ parent: StructElement?, _ index: Int) throws {
        if parent == nil && !(kid is StructElement) { throw ArgumentException(AccessibilityText.rootNeedsElement) }
        var p = parent
        while let up = p {
            if up === kid { throw ArgumentException(AccessibilityText.intoItself) }
            p = up.parent
        }
        detach(kid)
        insert(parent, kid, index)
    }

    private func insert(_ parent: StructElement?, _ kid: StructKid, _ index: Int) {
        if let parent {
            let at = index < 0 || index > parent.kidList.count ? parent.kidList.count : index
            parent.kidList.insert(kid, at: at)
        } else if let element = kid as? StructElement {
            let at = index < 0 || index > rootList.count ? rootList.count : index
            rootList.insert(element, at: at)
        }
        kid.parent = parent
    }

    private func detach(_ kid: StructKid) {
        if let parent = kid.parent {
            if let at = parent.kidList.firstIndex(where: { $0 === kid }) { parent.kidList.remove(at: at) }
        } else if let element = kid as? StructElement, let at = rootList.firstIndex(where: { $0 === element }) {
            rootList.remove(at: at)
        }
        kid.parent = nil
    }

    private func unmark(_ element: StructElement) {
        var stack = [element]
        while let e = stack.popLast() {
            if let reference = e.reference { removed.remove(reference.number) }
            stack.append(contentsOf: e.children)
        }
    }

    private func readAll() {
        var kids: [StructKid] = []
        readKid(dictionary["K"], nil, -1, 0, &kids)
        for case let kid as StructElement in kids {
            kid.parent = nil
            rootList.append(kid)
        }

        if let roles = document.dict(dictionary, "RoleMap") {
            for entry in roles.entries.prefix(10_000) {
                if let name = document.resolve(entry.value) as? PdfName { roleMap[entry.key] = name.value }
            }
        }
        if let classes = document.dict(dictionary, "ClassMap") {
            for entry in classes.entries.prefix(10_000) { classMap[entry.key] = entry.value }
        }
        parentTree = PdfNumberTree.read(document, dictionary["ParentTree"])
    }

    private func readKid(_ item: PdfObject?, _ parent: StructElement?, _ page: Int, _ depth: Int, _ into: inout [StructKid]) {
        if let list = item as? PdfArray {
            for entry in list.items.prefix(Self.maxNodes) { readKid(entry, parent, page, depth, &into) }
            return
        }
        nodes += 1
        if nodes > Self.maxNodes || depth > Self.maxDepth {
            isTruncated = true
            return
        }

        let value = document.resolve(item)
        if let resolvedList = value as? PdfArray {
            readKid(resolvedList, parent, page, depth + 1, &into)
            return
        }
        if let number = value as? PdfNumber, let mcid = number.integer {
            if mcid >= 0 && mcid <= Self.maxMcid {
                let content = StructContent(page, mcid)
                content.parent = parent
                into.append(content)
            }
            return
        }
        guard let d = value as? PdfDictionary else { return }

        let own = pageOf(d["Pg"])
        if readReference(d, own, page, parent, &into) { return }

        let reference = item as? PdfReference
        if let reference, byNumber[reference.number] != nil { return }
        let element = makeElement(d, reference, own, parent)
        if let reference { byNumber[reference.number] = element }
        var children: [StructKid] = []
        readKid(d["K"], element, own >= 0 ? own : page, depth + 1, &children)
        element.kidList.append(contentsOf: children)
        into.append(element)
    }

    // An MCR or an OBJR: a kid that is not an element. True when `d` was one.
    private func readReference(_ d: PdfDictionary, _ own: Int, _ page: Int, _ parent: StructElement?, _ into: inout [StructKid]) -> Bool {
        let kind = document.name(d, "Type")
        if kind == "MCR" || (d.containsKey("MCID") && !d.containsKey("S")) {
            if let id = document.integer(d, "MCID"), id >= 0, id <= Self.maxMcid {
                let content = StructContent(own >= 0 ? own : page, id, d["Stm"] as? PdfReference)
                content.parent = parent
                content.streamOwner = d["StmOwn"]
                into.append(content)
            }
            return true
        }
        if kind == "OBJR" || (d.containsKey("Obj") && !d.containsKey("S")) {
            if let target = d["Obj"] as? PdfReference {
                let object = StructObject(own >= 0 ? own : page, target)
                object.parent = parent
                into.append(object)
            }
            return true
        }
        return false
    }

    private func makeElement(_ d: PdfDictionary, _ reference: PdfReference?, _ own: Int, _ parent: StructElement?) -> StructElement {
        let element = StructElement(document.name(d, "S") ?? "", d, reference)
        element.title = PdfText.read(document, d, "T")
        element.alt = PdfText.read(document, d, "Alt")
        element.lang = PdfText.read(document, d, "Lang")
        element.actualText = PdfText.read(document, d, "ActualText")
        element.id = PdfText.read(document, d, "ID")
        element.pageIndex = own
        element.parent = parent
        return element
    }

    private func pageOf(_ reference: PdfObject?) -> Int {
        guard let reference = reference as? PdfReference else { return -1 }
        return pageByNumber[reference.number] ?? -1
    }
}
