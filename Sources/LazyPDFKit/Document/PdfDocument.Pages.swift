import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfDocument.Pages.cs: the page tree (ISO 32000-1 7.7.3), walked from the
// catalog without trusting it: /Count, /Type and /Parent are not needed, a loop or junk in /Kids costs only the
// entries it spoils.
//
// The document keeps the walk as plain nodes and `pages` makes the page objects from them, so that a page can hold
// its document without the two holding each other.

extension PdfDocument {
    private static let maxTreeDepth = 256

    private static let pageEvidence = ["Contents", "MediaBox", "Resources", "Parent"]

    /// The pages in reading order. The tree is walked on first use and kept; call `refreshPages` after changing it.
    public var pages: PdfPages {
        if let known = pageList { return PdfPages(self, known) }
        let walked = walkPages()
        pageList = walked
        return PdfPages(self, walked)
    }

    /// Forgets the page list so that the next use walks the tree again.
    func refreshPages() {
        pageList = nil
    }

    /// The state of one walk of the tree.
    private final class Walk {
        var pages: [PageNode] = []
        var visited = Set<Int>()
        var skipped = 0
    }

    private func walkPages() -> [PageNode] {
        let first = !pagesWalked
        pagesWalked = true
        let walk = Walk()
        if let root = catalog["Pages"] { visit(root, PageInheritance(), 0, walk) }

        if first {
            if walk.skipped > 0 {
                addRepair("The page tree has \(walk.skipped) entries that are not pages or that loop back; they were left out.")
            }
            if let declared = integer(dict(catalog, "Pages"), "Count"), declared != walk.pages.count, !walk.pages.isEmpty {
                addRepair("The page tree says \(declared) pages and has \(walk.pages.count).")
            }
            if walk.pages.isEmpty { findPagesByScan(walk) }
        }
        return walk.pages
    }

    private func visit(_ node: PdfObject, _ inherited: PageInheritance, _ depth: Int, _ walk: Walk) {
        let reference = node as? PdfReference
        if depth > Self.maxTreeDepth {
            walk.skipped += 1
            return
        }
        if let reference, !walk.visited.insert(reference.number).inserted {
            walk.skipped += 1
            return
        }
        guard let dictionary = resolve(node) as? PdfDictionary else {
            walk.skipped += 1
            return
        }
        let type = name(dictionary, "Type")
        let inherited = inheriting(dictionary, inherited)
        if type != "Page", let kids = array(dictionary, "Kids") {
            for kid in kids.items { visit(kid, inherited, depth + 1, walk) }
            return
        }
        if type == "Pages" { return }
        addPage(dictionary, reference, type, inherited, walk)
    }

    private func inheriting(_ dictionary: PdfDictionary, _ inherited: PageInheritance) -> PageInheritance {
        PageInheritance(
            resources: own(dictionary, "Resources") ?? inherited.resources, mediaBox: own(dictionary, "MediaBox") ?? inherited.mediaBox,
            cropBox: own(dictionary, "CropBox") ?? inherited.cropBox, rotate: own(dictionary, "Rotate") ?? inherited.rotate)
    }

    private func addPage(_ dictionary: PdfDictionary, _ reference: PdfReference?, _ type: String?, _ inherited: PageInheritance, _ walk: Walk) {
        // A page without a type is told by what pages have; a direct one cannot be referred to.
        let looksLikePage = type == "Page" || Self.pageEvidence.contains { dictionary.containsKey($0) }
        guard let reference, looksLikePage, type == nil || type == "Page" else {
            walk.skipped += 1
            return
        }
        walk.pages.append(PageNode(dictionary, reference, walk.pages.count, inherited))
    }

    private func own(_ dictionary: PdfDictionary, _ key: String) -> PdfObject? {
        if let value = dictionary[key], !(value is PdfNull) { return value }
        return nil
    }

    /// A tree with no pages in it, in a file that has page objects: they are used in the order they are in the file.
    private func findPagesByScan(_ walk: Walk) {
        for number in ensureScan().pages {
            let reference = PdfReference(number, generationOf(number))
            if let dictionary = get(number) as? PdfDictionary, name(dictionary, "Type") == "Page" {
                walk.pages.append(PageNode(dictionary, reference, walk.pages.count, PageInheritance()))
            }
        }
        if !walk.pages.isEmpty {
            addRepair("The page tree holds no pages; used the \(walk.pages.count) page objects found by scanning.")
        }
    }
}

/// The pages of a document in reading order; a page is made when it is asked for.
public struct PdfPages: RandomAccessCollection {
    private let document: PdfDocument
    private let nodes: [PageNode]

    init(_ document: PdfDocument, _ nodes: [PageNode]) {
        self.document = document
        self.nodes = nodes
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { nodes.count }

    public subscript(position: Int) -> PdfPage { PdfPage(document, nodes[position]) }
}
