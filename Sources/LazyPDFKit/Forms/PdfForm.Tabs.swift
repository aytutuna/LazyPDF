import Foundation

// Twin of windows/LazyPDF.Core/Forms/PdfForm.Tabs.cs: the order Tab visits the widgets of a page.

extension PdfForm {
    /// The page's /Tabs setting; `TabOrder.annotations` when it has none.
    public func getTabOrder(_ pageIndex: Int) -> TabOrder {
        switch document.name(pageAt(pageIndex).dictionary, "Tabs") {
        case "R": return .row
        case "C": return .column
        case "S": return .structure
        default: return .annotations
        }
    }

    public func setTabOrder(_ pageIndex: Int, _ order: TabOrder) {
        let page = pageAt(pageIndex)
        switch order {
        case .row: page.dictionary["Tabs"] = PdfName("R")
        case .column: page.dictionary["Tabs"] = PdfName("C")
        case .structure: page.dictionary["Tabs"] = PdfName("S")
        case .annotations: page.dictionary.remove("Tabs")
        }
    }

    /// The page's widgets in the order Tab visits them. Row order reads top to bottom and left to right, column order left to
    /// right and top to bottom; structure order is not followed and reads as the order of /Annots, which is also what no
    /// setting means.
    public func tabSequence(_ pageIndex: Int) -> [FormWidget] {
        let onPage = fields.flatMap { $0.widgets }.filter { $0.pageIndex == pageIndex }
        var position: [ObjectIdentifier: Int] = [:]
        if let annots = document.array(pageAt(pageIndex).dictionary, "Annots") {
            for (i, item) in annots.items.enumerated() {
                if let d = document.resolve(item) as? PdfDictionary, position[ObjectIdentifier(d)] == nil { position[ObjectIdentifier(d)] = i }
            }
        }
        let hasAnnots = document.array(pageAt(pageIndex).dictionary, "Annots") != nil
        let inFile = Self.stable(onPage, descending: false) { hasAnnots ? Double(position[ObjectIdentifier($0.dictionary)] ?? -1) : 0 }
        switch getTabOrder(pageIndex) {
        case .row:
            return Self.lines(inFile, { $0.rect.top }, { $0.rect.height }, { $0.rect.left }, descending: true)
        case .column:
            return Self.lines(inFile, { $0.rect.left }, { $0.rect.width }, { $0.rect.top }, descending: false, secondDescending: true)
        default:
            return inFile
        }
    }

    /// Sets the order Tab visits the listed widgets of a page by moving them within /Annots, keeping the slots they hold, and
    /// clears the page's /Tabs so that this order is the one used.
    public func reorderWidgets(_ pageIndex: Int, _ order: [FormWidget]) {
        let page = pageAt(pageIndex)
        page.dictionary.remove("Tabs")
        guard let annots = document.array(page.dictionary, "Annots") else { return }
        var slots: [Int] = []
        let members = Set(order.map { ObjectIdentifier($0.dictionary) })
        for i in 0..<annots.items.count {
            if let d = document.resolve(annots.items[i]) as? PdfDictionary, members.contains(ObjectIdentifier(d)) { slots.append(i) }
        }
        let items = order.compactMap { w in annots.items.first { document.resolve($0) === w.dictionary } }
        for i in 0..<min(slots.count, items.count) { annots.items[slots[i]] = items[i] }
    }

    // A stable sort by a number, as LINQ's OrderBy is.
    private static func stable(_ widgets: [FormWidget], descending: Bool, _ key: (FormWidget) -> Double) -> [FormWidget] {
        let keyed = widgets.enumerated().map { (index: $0.offset, key: key($0.element), widget: $0.element) }
        let sorted = keyed.sorted { a, b in
            if a.key == b.key { return a.index < b.index }
            return descending ? a.key > b.key : a.key < b.key
        }
        return sorted.map { $0.widget }
    }

    // Widgets grouped into lines by their position across (a line holds those within half the first one's size of it), lines in
    // order, each read along.
    private static func lines(_ widgets: [FormWidget], _ across: (FormWidget) -> Double, _ size: (FormWidget) -> Double,
                              _ along: (FormWidget) -> Double, descending: Bool, secondDescending: Bool = false) -> [FormWidget] {
        let sorted = stable(widgets, descending: descending, across)
        var lines: [[FormWidget]] = []
        for w in sorted {
            if let head = lines.last?.first, abs(across(head) - across(w)) <= size(head) / 2 {
                lines[lines.count - 1].append(w)
            } else {
                lines.append([w])
            }
        }
        return lines.flatMap { stable($0, descending: secondDescending, along) }
    }
}
