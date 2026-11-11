import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageOperations.Structure.cs: the operations that change the set or the order of pages.

extension PageOperations {
    /// Removes pages and what pointed at them: bookmarks and links keep their place but lose the destination, named
    /// destinations and form fields on the pages go, page labels are renumbered. A tagged document loses its structure tree
    /// when a removed page was tagged (the tree names pages and marked content by number, and is not edited). Refuses to
    /// remove every page.
    public static func delete(_ document: PdfDocument, _ pages: [Int]) throws {
        let doomed = select(document, pages)
        if doomed.isEmpty { return }
        let all = document.pages
        if doomed.count == all.count { throw PdfReadException.damaged("A document keeps at least one page.") }

        try PageCleanup.beforeDelete(document, doomed)
        let gone = Set(doomed.map { $0.reference.number })
        try PageTree.set(document, all.filter { !gone.contains($0.reference.number) }.map { $0.reference })
        for number in gone.sorted() { document.delete(number) }
    }

    /// The page at `order[i]` becomes page `i`. `order` must name every page once.
    public static func reorder(_ document: PdfDocument, _ order: [Int]) throws {
        let pages = document.pages
        precondition(order.count == pages.count && Set(order).count == order.count && order.allSatisfy { $0 >= 0 && $0 < pages.count },
                     "The order must name each page once.")
        if order.enumerated().allSatisfy({ $0.element == $0.offset }) { return }
        try PageTree.set(document, order.map { pages[$0].reference })
    }

    /// Moves the pages, in their own order, to stand before the page that is now at `before` (the page count puts them last).
    public static func move(_ document: PdfDocument, _ pages: [Int], _ before: Int) throws {
        let count = document.pages.count
        precondition(before >= 0 && before <= count, "before")
        let moved = select(document, pages).map { $0.index }
        let movedSet = Set(moved)
        let rest = (0..<count).filter { !movedSet.contains($0) }
        let at = rest.filter { $0 < before }.count
        try reorder(document, Array(rest.prefix(at)) + moved + Array(rest.dropFirst(at)))
    }

    /// Puts a copy of each page right after it. Content, fonts and images are shared with the original; annotations and
    /// form fields are copied, and a copied field is renamed ("name_2").
    public static func duplicate(_ document: PdfDocument, _ pages: [Int]) throws {
        let chosen = select(document, pages)
        if chosen.isEmpty { return }
        let copies = try PageImporter(document, document).importPages(chosen.map { $0.index })
        var after: [Int: PdfReference] = [:]
        for (i, page) in chosen.enumerated() { after[page.index] = copies[i] }
        var order: [PdfReference] = []
        for page in document.pages {
            order.append(page.reference)
            if let copy = after[page.index] { order.append(copy) }
        }
        for index in chosen.map({ $0.index }).reversed() { try PageLabels.inserted(document, index + 1, 1) }
        try PageTree.set(document, order)
    }

    /// Inserts `count` empty pages of the given size in points so that the first is page `at`.
    public static func insertBlank(_ document: PdfDocument, _ at: Int, _ width: Double, _ height: Double, _ count: Int = 1) throws {
        precondition(at >= 0 && at <= document.pages.count, "at")
        precondition(count >= 1, "count")
        if !(width > 0 && width <= maxPageSize && height > 0 && height <= maxPageSize) { throw PdfReadException.damaged("The size is out of range.") }
        var blank: [PdfReference] = []
        for _ in 0..<count {
            let page = PdfDictionary()
            let box = PdfRect(0, 0, width, height)
            page["Type"] = PdfName("Page")
            page["MediaBox"] = box.toArray()
            page["CropBox"] = box.toArray()
            page["Rotate"] = PdfNumber(0)
            page["Resources"] = PdfDictionary()
            blank.append(try document.add(page))
        }
        try insertAt(document, at, blank)
    }

    /// Copies pages of `source` into `target` so that the first is page `at`. Everything a page needs is copied once per
    /// call, however many pages share it; the source's tree, tags and article threads stay behind. Links to pages
    /// that did not come across are dropped; form fields join the target's /AcroForm and are renamed on a clash. The source's
    /// bookmarks that point at the pages come across at the end of the target's top level (a parent stays when something
    /// under it does). The source may be the target, which then gets no bookmarks.
    public static func importPages(_ target: PdfDocument, _ source: PdfDocument, _ sourcePages: [Int], _ at: Int) throws {
        precondition(at >= 0 && at <= target.pages.count, "at")
        if sourcePages.isEmpty { return }
        try insertAt(target, at, PageImporter(source, target).importPages(sourcePages))
        if source !== target {
            var newIndex: [Int: Int] = [:]
            for (i, page) in sourcePages.enumerated() where newIndex[page] == nil { newIndex[page] = at + i }
            try PageCarry.bookmarks(source, target, newIndex, nil)
            let origins: [AnyObject] = target.pages.indices.map { $0 >= at && $0 < at + sourcePages.count ? source : target }
            try StampRuns.separate(target, zip(target.pages, origins).map { (page: $0, origin: $1) })
        }
    }

    private static func insertAt(_ document: PdfDocument, _ at: Int, _ added: [PdfReference]) throws {
        var order = document.pages.map { $0.reference }
        order.insert(contentsOf: added, at: at)
        try PageLabels.inserted(document, at, added.count)
        try PageTree.set(document, order)
    }
}
