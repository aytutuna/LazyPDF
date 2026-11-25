import Foundation

// Twin of windows/LazyPDF.Core/Pages/TagCut.cs: which elements of the source's tag tree have nothing left on the pages
// taken, found without copying anything, so that a part never copies the tree of the pages it leaves out. Follows
// RedactionStructure.prune, with the pages left out as the ones whose content is removed.
enum TagCut {
    private static let maxDepth = 64

    /// The object numbers of the elements to leave out, given the numbers of the pages taken and of all the source's pages.
    static func dead(_ source: PdfDocument, _ root: PdfObject, _ taken: Set<Int>, _ pages: Set<Int>) -> Set<Int> {
        var dead = Set<Int>()
        if let top = source.resolve(root) as? PdfDictionary {
            var seen = Set<ObjectIdentifier>()
            _ = alive(source, top, nil, taken, pages, &dead, &seen, 0)
        }
        return dead
    }

    private static func alive(_ source: PdfDocument, _ element: PdfDictionary, _ inherited: Int?, _ taken: Set<Int>, _ pages: Set<Int>,
                              _ dead: inout Set<Int>, _ seen: inout Set<ObjectIdentifier>, _ depth: Int) -> Bool {
        if depth > maxDepth || !seen.insert(ObjectIdentifier(element)).inserted { return true }
        let page = pageOf(element, inherited, pages)
        func shown(_ at: Int?) -> Bool { at.map { taken.contains($0) } ?? true }
        var kids: [PdfObject] = []
        if let array = source.resolve(element["K"]) as? PdfArray {
            kids = array.items
        } else if let single = element["K"] {
            kids = [single]
        }
        var kept = 0
        for kid in kids {
            switch source.resolve(kid) {
            case is PdfNumber:
                if shown(page) { kept += 1 }
            case let d as PdfDictionary where RedactionStructure.isContentItem(source, d, "MCR", "MCID"):
                if d.containsKey("Stm") || shown(pageOf(d, page, pages)) { kept += 1 }
            case let d as PdfDictionary where RedactionStructure.isContentItem(source, d, "OBJR", "Obj"):
                if source.resolve(d["Obj"]) != nil && shown(pageOf(d, page, pages)) { kept += 1 }
            case let child as PdfDictionary:
                if alive(source, child, page, taken, pages, &dead, &seen, depth + 1) {
                    kept += 1
                } else if let reference = kid as? PdfReference {
                    dead.insert(reference.number)
                }
            default:
                break
            }
        }
        return kept > 0 || kids.isEmpty
    }

    private static func pageOf(_ item: PdfDictionary, _ inherited: Int?, _ pages: Set<Int>) -> Int? {
        if let own = item["Pg"] as? PdfReference, pages.contains(own.number) { return own.number }
        return inherited
    }
}
