import Foundation

// Twin of windows/LazyPDF.Core/Structure/NameTrees.cs: name trees (ISO 32000-1 7.9.6) and number trees (7.9.7).
// An entry is a `(key:, value:)` pair, as the C# KeyValuePair is.

/// Byte-string keys to values, in key order. A key is held as a string with one character per byte, so it is the same
/// under any text encoding and compares as the file compares it; `keyOf` and `textOf` go to and from text.
public enum PdfNameTree {
    public static func keyOf(_ text: String) -> String { Latin1.string(PdfText.encode(text)) }

    public static func textOf(_ key: String) -> String { PdfText.decode(Latin1.bytes(key)) }

    /// The entries of the tree rooted at `root`, in the order met; values as stored (not resolved). A loop, a branch
    /// past 32 levels or more than a million entries is cut off.
    public static func read(_ document: PdfDocument, _ root: PdfObject?) -> [(key: String, value: PdfObject)] {
        var entries: [(key: String, value: PdfObject)] = []
        for leaf in PdfTrees.leaves(document, root, "Names") {
            if let s = document.resolve(leaf.key) as? PdfString { entries.append((Latin1.string(s.bytes), leaf.value)) }
        }
        return entries
    }

    /// Rebuilds the tree from `entries` (a repeated key: the last one counts) and returns its root, which is `existing`
    /// changed in place when there is one. The old child nodes are freed.
    public static func write(_ document: PdfDocument, _ existing: PdfDictionary?, _ entries: [(key: String, value: PdfObject)]) throws -> PdfDictionary {
        var last: [String: PdfObject] = [:]
        for entry in entries { last[entry.key] = entry.value }
        // SortedDictionary with StringComparer.Ordinal: UTF-16 code units.
        let sorted = last.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
        return try PdfTrees.write(document, existing, "Names",
                                  sorted.map { (key: PdfString(bytes: Latin1.bytes($0.key), isHex: false) as PdfObject, value: $0.value) })
    }
}

public enum PdfNumberTree {
    public static func read(_ document: PdfDocument, _ root: PdfObject?) -> [(key: Int, value: PdfObject)] {
        var entries: [(key: Int, value: PdfObject)] = []
        for leaf in PdfTrees.leaves(document, root, "Nums") {
            if let n = (document.resolve(leaf.key) as? PdfNumber)?.integer { entries.append((n, leaf.value)) }
        }
        return entries
    }

    public static func write(_ document: PdfDocument, _ existing: PdfDictionary?, _ entries: [(key: Int, value: PdfObject)]) throws -> PdfDictionary {
        var last: [Int: PdfObject] = [:]
        for entry in entries { last[entry.key] = entry.value }
        let sorted = last.sorted { $0.key < $1.key }
        return try PdfTrees.write(document, existing, "Nums", sorted.map { (key: PdfNumber($0.key) as PdfObject, value: $0.value) })
    }
}

enum PdfTrees {
    private static let maxDepth = 32
    private static let maxEntries = 1_000_000
    private static let nodeSize = 64

    static func leaves(_ document: PdfDocument, _ root: PdfObject?, _ leafKey: String) -> [(key: PdfObject, value: PdfObject)] {
        var found: [(key: PdfObject, value: PdfObject)] = []
        var visited = Set<Int>()
        walk(document, root, leafKey, 0, &found, &visited)
        return found
    }

    private static func walk(_ document: PdfDocument, _ node: PdfObject?, _ leafKey: String, _ depth: Int,
                             _ found: inout [(key: PdfObject, value: PdfObject)], _ visited: inout Set<Int>) {
        if depth > maxDepth || found.count >= maxEntries { return }
        if let reference = node as? PdfReference, !visited.insert(reference.number).inserted { return }
        guard let dictionary = document.resolve(node) as? PdfDictionary else { return }
        collect(document, dictionary, leafKey, &found)
        guard let kids = document.array(dictionary, "Kids") else { return }
        for kid in kids.items { walk(document, kid, leafKey, depth + 1, &found, &visited) }
    }

    private static func collect(_ document: PdfDocument, _ dictionary: PdfDictionary, _ leafKey: String, _ found: inout [(key: PdfObject, value: PdfObject)]) {
        guard let leaves = document.array(dictionary, leafKey) else { return }
        var i = 0
        while i + 1 < leaves.items.count && found.count < maxEntries {
            found.append((leaves.items[i], leaves.items[i + 1]))
            i += 2
        }
    }

    static func write(_ document: PdfDocument, _ existing: PdfDictionary?, _ leafKey: String,
                      _ sorted: [(key: PdfObject, value: PdfObject)]) throws -> PdfDictionary {
        let root = existing ?? PdfDictionary()
        freeKids(document, root)
        root.remove("Names")
        root.remove("Nums")
        root.remove("Kids")
        root.remove("Limits")
        if sorted.count <= nodeSize {
            root[leafKey] = pairs(sorted)
            return root
        }

        var level: [(first: PdfObject, last: PdfObject, node: PdfReference)] = []
        for i in stride(from: 0, to: sorted.count, by: nodeSize) {
            let chunk = Array(sorted[i..<Swift.min(i + nodeSize, sorted.count)])
            let leaf = PdfDictionary()
            leaf[leafKey] = pairs(chunk)
            leaf["Limits"] = PdfArray([chunk[0].key, chunk[chunk.count - 1].key])
            let node = try document.add(leaf)
            level.append((chunk[0].key, chunk[chunk.count - 1].key, node))
        }
        while level.count > nodeSize {
            var upper: [(first: PdfObject, last: PdfObject, node: PdfReference)] = []
            for i in stride(from: 0, to: level.count, by: nodeSize) {
                let chunk = Array(level[i..<Swift.min(i + nodeSize, level.count)])
                let node = PdfDictionary()
                node["Kids"] = PdfArray(chunk.map { $0.node })
                node["Limits"] = PdfArray([chunk[0].first, chunk[chunk.count - 1].last])
                let reference = try document.add(node)
                upper.append((chunk[0].first, chunk[chunk.count - 1].last, reference))
            }
            level = upper
        }
        root["Kids"] = PdfArray(level.map { $0.node })
        return root
    }

    private static func pairs(_ entries: [(key: PdfObject, value: PdfObject)]) -> PdfArray {
        var items: [PdfObject] = []
        items.reserveCapacity(entries.count * 2)
        for entry in entries {
            items.append(entry.key)
            items.append(entry.value)
        }
        return PdfArray(items)
    }

    private static func freeKids(_ document: PdfDocument, _ node: PdfDictionary) {
        var visited = Set<Int>()
        var budget = 100_000
        free(document, node, 0, &visited, &budget)
    }

    private static func free(_ document: PdfDocument, _ current: PdfDictionary, _ depth: Int, _ visited: inout Set<Int>, _ budget: inout Int) {
        guard depth <= maxDepth, let kids = document.array(current, "Kids") else { return }
        for kid in kids.items {
            guard let reference = kid as? PdfReference else { continue }
            budget -= 1
            guard budget >= 0, visited.insert(reference.number).inserted else { continue }
            if let child = document.get(reference.number) as? PdfDictionary { free(document, child, depth + 1, &visited, &budget) }
            document.delete(reference.number)
        }
    }
}
