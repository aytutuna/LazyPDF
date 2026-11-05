import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageTree.cs: the page tree as the editing code leaves it. Every change to the order
// or the set of pages ends in `set`, which lays the tree out again. A node holds at most `fanout` kids (ISO 32000-1
// 7.7.3.2 puts no limit on it; other readers cope better with a shallow, even tree than with 5000 kids in one array).

enum PageTree {
    private static let fanout = 32
    private static let maxNodes = 1_000_000
    private static let inheritable = ["Resources", "MediaBox", "CropBox", "Rotate"]

    private struct Node {
        let ref: PdfReference
        let dict: PdfDictionary
    }

    private final class Layout {
        var interior: [Node] = []
        var pageParent: [Int: PdfDictionary] = [:]
        var nodeParent: [ObjectIdentifier: PdfDictionary] = [:]
    }

    private final class Spare {
        let nodes: [Node]
        var next = 0

        init(_ nodes: [Node]) {
            self.nodes = nodes
        }

        func take() -> Node? {
            guard next < nodes.count else { return nil }
            next += 1
            return nodes[next - 1]
        }
    }

    /// Makes `order` the pages of the document, in that order. Values a page took from a node that is going away are
    /// written onto the page first. Inner nodes of the old tree are reused where the new one needs them, so that an edit
    /// near the end of a big file does not rewrite the whole tree.
    static func set(_ document: PdfDocument, _ order: [PdfReference]) throws {
        let (root, rootRef) = try rootNode(document)
        let layout = walk(document, root, rootRef.number)
        let kept = Set(order.map { $0.number })
        for page in document.pages where kept.contains(page.reference.number) { bake(page, root, layout) }

        let spare = Spare(layout.interior)
        let leaves = try order.map { reference -> Node in
            guard let dict = document.resolve(reference) as? PdfDictionary else { throw PdfReadException.damaged("A page of the document is missing.") }
            return Node(ref: reference, dict: dict)
        }
        try fill(document, root, rootRef, leaves[...], spare)
        if document.name(root, "Type") != "Pages" { root["Type"] = PdfName("Pages") }
        for node in spare.nodes[spare.next...] { document.delete(node.ref.number) }
        document.refreshPages()
    }

    private static func rootNode(_ document: PdfDocument) throws -> (PdfDictionary, PdfReference) {
        let raw = document.catalog["Pages"]
        if let reference = raw as? PdfReference, let found = document.resolve(reference) as? PdfDictionary { return (found, reference) }
        let root = document.resolve(raw) as? PdfDictionary ?? PdfDictionary()
        let added = try document.add(root)
        document.catalog["Pages"] = added
        return (root, added)
    }

    private static func fill(_ document: PdfDocument, _ node: PdfDictionary, _ nodeRef: PdfReference, _ leaves: ArraySlice<Node>,
                             _ spare: Spare) throws {
        var kids: [PdfObject] = []
        if leaves.count <= fanout {
            for leaf in leaves {
                leaf.dict["Parent"] = nodeRef
                kids.append(leaf.ref)
            }
        } else {
            // The smallest power of the fan-out with which no more than fanout children are needed.
            var each = fanout
            while each * fanout < leaves.count { each *= fanout }
            var at = leaves.startIndex
            while at < leaves.endIndex {
                let end = min(at + each, leaves.endIndex)
                let child = try spare.take() ?? newNode(document)
                reset(child.dict)
                child.dict["Type"] = PdfName("Pages")
                child.dict["Parent"] = nodeRef
                try fill(document, child.dict, child.ref, leaves[at..<end], spare)
                kids.append(child.ref)
                at = end
            }
        }
        node["Kids"] = PdfArray(kids)
        node["Count"] = PdfNumber(leaves.count)
    }

    private static func newNode(_ document: PdfDocument) throws -> Node {
        let node = PdfDictionary()
        return Node(ref: try document.add(node), dict: node)
    }

    private static func reset(_ node: PdfDictionary) {
        for key in node.entries.map({ $0.key }) { node.remove(key) }
    }

    private static func bake(_ page: PdfPage, _ root: PdfDictionary, _ layout: Layout) {
        guard let parent = layout.pageParent[page.reference.number] else { return }
        for key in inheritable {
            if let own = page.dictionary[key], !(own is PdfNull) { continue }
            var node: PdfDictionary? = parent
            var depth = 0
            while let current = node, current !== root, depth < 256 {
                if let value = current[key], !(value is PdfNull) {
                    page.dictionary[key] = value
                    break
                }
                node = layout.nodeParent[ObjectIdentifier(current)]
                depth += 1
            }
        }
    }

    /// The inner nodes below the root in the order a layout visits them, and which node holds each page, by following /Kids
    /// only, as the reader does.
    private static func walk(_ document: PdfDocument, _ root: PdfDictionary, _ rootNumber: Int) -> Layout {
        let layout = Layout()
        var seen: Set<Int> = [rootNumber]
        var stack: [(ref: PdfReference?, dict: PdfDictionary)] = [(nil, root)]
        while seen.count < maxNodes, let (ref, node) = stack.popLast() {
            if let ref { layout.interior.append(Node(ref: ref, dict: node)) }
            var inner: [Node] = []
            if let kids = document.array(node, "Kids") {
                for kid in kids.items {
                    guard let reference = kid as? PdfReference, seen.insert(reference.number).inserted else { continue }
                    guard let child = document.resolve(reference) as? PdfDictionary else { continue }
                    let type = document.name(child, "Type")
                    if type != "Page" && (type == "Pages" || child.containsKey("Kids")) {
                        layout.nodeParent[ObjectIdentifier(child)] = node
                        inner.append(Node(ref: reference, dict: child))
                    } else {
                        layout.pageParent[reference.number] = node
                    }
                }
            }
            for item in inner.reversed() { stack.append((item.ref, item.dict)) }
        }
        return layout
    }
}
