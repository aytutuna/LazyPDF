import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/AccessibilityChecker.Structure.cs: the rules that read the structure tree and
// the form. `below` is a walk with a stack where the C# recurses, so a deep tree costs no stack.

extension AccessibilityChecker {
    private static let structureRules: [AccessibilityRule] = [
        .figureAlt, .tableStructure, .tableHeaders, .listStructure, .headingOrder, .roleMap, .links, .formTagged,
    ]

    static func checkStructure(_ document: PdfDocument, _ tree: StructureTree?) -> [AccessibilityItem] {
        let form = PdfForm.read(document)
        var items = [formNames(form)]
        guard let tree else {
            for rule in structureRules { items.append(noTags(rule)) }
            return items
        }

        let elements = tree.elements
        let type: (StructElement) -> String = { tree.standardType($0.type) }
        items.append(figureAlt(elements, type))
        items.append(tables(document, elements, type, headers: false))
        items.append(tables(document, elements, type, headers: true))
        items.append(lists(elements, type))
        items.append(headingOrder(elements, type))
        items.append(roleMap(tree, elements))
        items.append(links(document, tree, elements, type))
        items.append(formTagged(form, elements))
        return items
    }

    private static func pageOf(_ element: StructElement) -> Int {
        if element.pageIndex >= 0 { return element.pageIndex }
        for kid in element.kids {
            if let content = kid as? StructContent, content.pageIndex >= 0 { return content.pageIndex }
            if let target = kid as? StructObject, target.pageIndex >= 0 { return target.pageIndex }
        }
        return -1
    }

    private static func hasText(_ element: StructElement) -> Bool {
        !DotNetText.isNullOrWhiteSpace(element.alt) || !DotNetText.isNullOrWhiteSpace(element.actualText)
    }

    // Whether any element below `element` is one `test` accepts.
    private static func anyBelow(_ element: StructElement, _ test: (StructElement) -> Bool) -> Bool {
        var stack = element.children
        while let next = stack.popLast() {
            if test(next) { return true }
            stack.append(contentsOf: next.children)
        }
        return false
    }

    // 7.3 of ISO 14289-1: a figure has alternate text.
    private static func figureAlt(_ elements: [StructElement], _ type: (StructElement) -> String) -> AccessibilityItem {
        let found = Found()
        for e in elements where type(e) == "Figure" && !hasText(e) {
            found.add(pageOf(e), e.reference)
        }
        return found.count == 0 ? pass(.figureAlt) : fail(.figureAlt, found)
    }

    // 7.5: a table has rows of cells, every row the same width, and header cells.
    private static func tables(_ document: PdfDocument, _ elements: [StructElement], _ type: (StructElement) -> String, headers: Bool) -> AccessibilityItem {
        let found = Found()
        for table in elements where type(table) == "Table" {
            let ok = headers ? anyBelow(table, { type($0) == "TH" }) : isRegular(document, table, type)
            if !ok { found.add(pageOf(table), table.reference) }
        }
        let rule: AccessibilityRule = headers ? .tableHeaders : .tableStructure
        return found.count == 0 ? pass(rule) : fail(rule, found)
    }

    private static func isRegular(_ document: PdfDocument, _ table: StructElement, _ type: (StructElement) -> String) -> Bool {
        var rows: [StructElement] = []
        for child in table.children {
            let t = type(child)
            if t == "TR" {
                rows.append(child)
            } else if t == "THead" || t == "TBody" || t == "TFoot" {
                for row in child.children {
                    if type(row) != "TR" { return false }
                    rows.append(row)
                }
            } else if t != "Caption" {
                return false
            }
        }
        if rows.isEmpty { return false }

        var widths = Set<Int>()
        for row in rows {
            let cells = row.children
            if cells.isEmpty || cells.contains(where: { type($0) != "TH" && type($0) != "TD" }) { return false }
            if cells.contains(where: { hasSpan(document, $0) }) { return true }
            widths.insert(cells.count)
        }
        return widths.count == 1
    }

    private static func hasSpan(_ document: PdfDocument, _ cell: StructElement) -> Bool {
        let attributes = document.resolve(cell.dictionary["A"])
        let dictionaries: [PdfDictionary]
        if let d = attributes as? PdfDictionary {
            dictionaries = [d]
        } else if let a = attributes as? PdfArray {
            dictionaries = a.items.compactMap { document.resolve($0) as? PdfDictionary }
        } else {
            dictionaries = []
        }
        return dictionaries.contains { $0.containsKey("RowSpan") || $0.containsKey("ColSpan") }
    }

    // 7.6: L holds LI, LI holds Lbl and LBody.
    private static func lists(_ elements: [StructElement], _ type: (StructElement) -> String) -> AccessibilityItem {
        let found = Found()
        for e in elements {
            let ok: Bool
            switch type(e) {
            case "L":
                ok = e.children.allSatisfy { type($0) == "LI" || type($0) == "Caption" }
            case "LI":
                ok = type(e.parent ?? e) == "L" && e.children.allSatisfy { type($0) == "Lbl" || type($0) == "LBody" || type($0) == "L" }
            case "Lbl", "LBody":
                ok = e.parent.map { type($0) == "LI" } ?? false
            default:
                ok = true
            }
            if !ok { found.add(pageOf(e), e.reference) }
        }
        return found.count == 0 ? pass(.listStructure) : fail(.listStructure, found)
    }

    // 7.4: H1 comes first, a level is never skipped going down, and H is not mixed with H1 to H6.
    private static func headingOrder(_ elements: [StructElement], _ type: (StructElement) -> String) -> AccessibilityItem {
        let found = Found()
        var previous: Int32 = 0
        var plain = false, numbered = false
        for e in elements {
            let t = type(e)
            if t == "H" {
                plain = true
                if numbered { found.add(pageOf(e), e.reference) }
            } else if t.utf16.count > 1, t.utf16.first == 0x48, let level = headingLevel(t) {
                numbered = true
                // previous + 1 wraps in the C# int, as the level can be up to int.MaxValue.
                if plain || level > previous &+ 1 || level > 6 { found.add(pageOf(e), e.reference) }
                previous = level
            }
        }
        return found.count == 0 ? pass(.headingOrder) : fail(.headingOrder, found)
    }

    // int.TryParse(t.AsSpan(1)): white space, a sign and digits, and trailing null characters, which .NET ignores.
    private static func headingLevel(_ type: String) -> Int32? {
        var scalars = Array(type.unicodeScalars.dropFirst())
        while scalars.last == "\0" { scalars.removeLast() }
        guard let level = InvariantNumbers.parseInt(String(String.UnicodeScalarView(scalars))) else { return nil }
        return Int32(exactly: level)
    }

    // 7.1: a type that is not standard is mapped to one that is.
    private static func roleMap(_ tree: StructureTree, _ elements: [StructElement]) -> AccessibilityItem {
        let found = Found()
        var seen = Set<String>()
        for e in elements {
            if !StructureTree.isStandard(tree.standardType(e.type)) && seen.insert(e.type).inserted { found.add(pageOf(e), e.reference) }
        }
        return found.count == 0 ? pass(.roleMap) : fail(.roleMap, found)
    }

    // 7.18.5: a link annotation sits in a Link element and has text for a reader.
    private static func links(_ document: PdfDocument, _ tree: StructureTree, _ elements: [StructElement], _ type: (StructElement) -> String) -> AccessibilityItem {
        var owners: [Int: StructElement] = [:]
        for e in elements {
            for case let target as StructObject in e.kids where owners[target.target.number] == nil {
                owners[target.target.number] = e
            }
        }

        let found = Found()
        var budget = 50_000
        for page in document.pages {
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            for item in annots.items {
                budget -= 1
                if budget < 0 { break }
                guard let reference = item as? PdfReference, let annotation = document.resolve(item) as? PdfDictionary,
                      document.name(annotation, "Subtype") == "Link" else { continue }
                let described = !DotNetText.isNullOrWhiteSpace(PdfText.read(document, annotation, "Contents"))
                if let owner = owners[reference.number] {
                    if !described && !hasText(owner) && !hasContent(owner) { found.add(page.index, reference) }
                } else {
                    found.add(page.index, reference)
                }
            }
        }
        for e in elements where type(e) == "Link" && e.kids.isEmpty && !hasText(e) { found.add(pageOf(e), e.reference) }
        return found.count == 0 ? pass(.links) : fail(.links, found)
    }

    private static func hasContent(_ element: StructElement) -> Bool {
        element.kids.contains { $0 is StructContent } || anyBelow(element, { $0.kids.contains { $0 is StructContent } })
    }

    // 7.18.1 and 7.18.4: a field has a name and a description.
    private static func formNames(_ form: PdfForm) -> AccessibilityItem {
        let found = Found()
        for field in form.fields {
            if DotNetText.isNullOrWhiteSpace(field.name) || DotNetText.isNullOrWhiteSpace(field.tooltip) {
                found.add(field.widgets.first?.pageIndex ?? -1, field.reference)
            }
        }
        return found.count == 0 ? pass(.formNames) : fail(.formNames, found)
    }

    private static func formTagged(_ form: PdfForm, _ elements: [StructElement]) -> AccessibilityItem {
        var tagged = Set<Int>()
        for e in elements {
            for case let target as StructObject in e.kids { tagged.insert(target.target.number) }
        }
        let found = Found()
        for field in form.fields {
            for widget in field.widgets {
                if let reference = widget.reference, !tagged.contains(reference.number) { found.add(widget.pageIndex, reference) }
            }
        }
        return found.count == 0 ? pass(.formTagged) : fail(.formTagged, found)
    }
}
