import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionStructure.cs: the tag tree after a redaction (ISO 32000-1 14.7): an element
// whose marked content or annotation is gone leaves the tree, and an element that lost some of its content loses the
// /ActualText, /Alt and /E that may repeat it. The parent and ID trees stop pointing at the elements that left.

enum RedactionStructure {
    private static let maxDepth = 64
    private static let maxElements = 1_000_000

    private static let altKeys = ["ActualText", "Alt", "E", "T", "AF"]

    typealias Tagged = [Int: [Int: (total: Int, removed: Int)]]

    /// `tagged`: per page object number, how many items each marked content ID painted and how many of them were removed.
    /// `pictures`: the object numbers of pages that became a picture: everything they showed is gone.
    /// `replaced`: pictures and forms that were copied or dropped, and what else was dropped; a content item or object that
    /// still names the original would keep it in the file.
    static func prune(_ document: PdfDocument, _ tagged: Tagged, _ replaced: RedactionObjects.Identities, _ pictures: Set<Int>) throws {
        guard let root = document.dict(document.catalog, "StructTreeRoot") else { return }
        var gone = RedactionObjects.Identities()
        var budget = maxElements
        _ = visit(document, root, nil, tagged, replaced, pictures, &gone, 0, &budget)
        if gone.isEmpty { return }

        func left(_ value: PdfObject?) -> Bool {
            guard let d = document.resolve(value) as? PdfDictionary else { return false }
            return gone.contains(d)
        }
        if let parents = document.resolve(root["ParentTree"]) as? PdfDictionary {
            var kept: [(key: Int, value: PdfObject)] = []
            for (key, value) in PdfNumberTree.read(document, parents) {
                if let list = document.resolve(value) as? PdfArray {
                    for i in 0..<list.items.count where left(list.items[i]) { list.items[i] = PdfNull.instance }
                    kept.append((key, value))
                } else if !left(value) {
                    kept.append((key, value))
                }
            }
            _ = try PdfNumberTree.write(document, parents, kept)
        }
        if let ids = document.resolve(root["IDTree"]) as? PdfDictionary {
            let kept = PdfNameTree.read(document, ids).filter { !left($0.value) }
            _ = try PdfNameTree.write(document, ids, kept)
        }
    }

    /// Whether the element still has content; elements that have none are added to `gone` by their parent.
    private static func visit(_ document: PdfDocument, _ element: PdfDictionary, _ inherited: Int?, _ tagged: Tagged, _ replaced: RedactionObjects.Identities,
                              _ pictures: Set<Int>, _ gone: inout RedactionObjects.Identities, _ depth: Int, _ budget: inout Int) -> (alive: Bool, touched: Bool) {
        var over = depth > maxDepth
        if !over {
            budget -= 1
            over = budget < 0
        }
        if over {
            strip(document, element)
            return (true, true)
        }
        var page = inherited
        if let own = element["Pg"] as? PdfReference { page = own.number }
        var kids: [PdfObject] = []
        if let array = document.resolve(element["K"]) as? PdfArray {
            kids = array.items
        } else if let single = element["K"] {
            kids = [single]
        }
        var kept: [PdfObject] = []
        var touched = false
        for kid in kids {
            switch document.resolve(kid) {
            case let n as PdfNumber:
                let lost = content(page, Int(saturating32: n.value), tagged, pictures, &kept, kid)
                touched = touched || lost
            case let d as PdfDictionary where isContentItem(document, d, "MCR", "MCID"):
                let at = (d["Pg"] as? PdfReference)?.number ?? page
                if d.containsKey("Stm") {
                    if let form = document.resolve(d["Stm"]) as? PdfStream, replaced.contains(form) {
                        touched = true
                    } else {
                        kept.append(kid)
                    }
                } else {
                    let lost = content(at, Int(saturating32: Double(document.integer(d, "MCID") ?? -1)), tagged, pictures, &kept, kid)
                    touched = touched || lost
                }
            case let d as PdfDictionary where isContentItem(document, d, "OBJR", "Obj"):
                let target = document.resolve(d["Obj"])
                if target == nil || ((target as? PdfStream).map { replaced.contains($0) } ?? false) {
                    touched = true
                } else {
                    kept.append(kid)
                }
            case let child as PdfDictionary:
                let (alive, inner) = visit(document, child, page, tagged, replaced, pictures, &gone, depth + 1, &budget)
                touched = touched || inner
                if alive {
                    kept.append(kid)
                } else {
                    gone.insert(child)
                    touched = true
                }
            default:
                break
            }
        }
        if kept.count != kids.count {
            if kept.isEmpty {
                element.remove("K")
            } else {
                element["K"] = PdfArray(kept)
            }
        }
        if touched { for key in altKeys { element.remove(key) } }
        // The root has no content of its own and stays.
        return (!kept.isEmpty || kids.isEmpty, touched)
    }

    // Past the limits the tree is not followed, so no description below can be vouched for and none stays.
    private static func strip(_ document: PdfDocument, _ element: PdfDictionary) {
        var seen = RedactionObjects.Identities()
        var open = [element]
        while let current = open.popLast() {
            if !seen.insert(current) { continue }
            for key in altKeys { current.remove(key) }
            let kids = document.resolve(current["K"])
            let list: [PdfObject] = (kids as? PdfArray)?.items ?? (kids.map { [$0] } ?? [])
            for kid in list {
                if let child = document.resolve(kid) as? PdfDictionary { open.append(child) }
            }
        }
    }

    // The type is required, but a writer that leaves it out still has a content item when there is no structure type.
    private static func isContentItem(_ document: PdfDocument, _ item: PdfDictionary, _ type: String, _ key: String) -> Bool {
        document.name(item, "Type") == type || (!item.containsKey("S") && !item.containsKey("Type") && item.containsKey(key))
    }

    // True when the content lost something; it stays in the tree unless every item it painted is gone.
    private static func content(_ page: Int?, _ mcid: Int, _ tagged: Tagged, _ pictures: Set<Int>, _ kept: inout [PdfObject], _ kid: PdfObject) -> Bool {
        // With no page to match, the number is taken on every page.
        guard let shown = page else {
            kept.append(kid)
            return !pictures.isEmpty || tagged.values.contains { ($0[mcid]?.removed ?? 0) > 0 }
        }
        if pictures.contains(shown) { return true }
        if let c = tagged[shown]?[mcid], c.removed > 0 {
            if c.removed < c.total { kept.append(kid) }
            return true
        }
        kept.append(kid)
        return false
    }
}
