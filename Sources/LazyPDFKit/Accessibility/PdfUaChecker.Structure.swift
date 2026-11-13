import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PdfUaChecker.Structure.cs: the tags, role map, nesting, headings, alternate text
// and notes (ISO 14289-1 7.1 to 7.9). Type names are compared as UTF-16 code units, as the C# compares them ordinally.

private let tableParts: Set<String> = ["THead", "TBody", "TFoot"]

// Types whose own parent is checked, so a wrong child is not reported a second time from the parent.
private let placed: Set<String> = ["THead", "TBody", "TFoot", "TR", "TH", "TD", "LI", "Lbl", "LBody"]

private func ordinalPrecedes(_ a: String, _ b: String) -> Bool {
    a.utf16.lexicographicallyPrecedes(b.utf16)
}

extension PdfUaChecker {
    func checkStructure() {
        guard let tree else { return }
        let elements = tree.elements
        let type: (StructElement) -> String = { tree.standardType($0.type) }
        checkRoleMap(tree, elements)
        checkNesting(elements, type)
        checkHeadings(elements, type)

        var notes = Set<OrdinalString>()
        for element in elements {
            let t = type(element)
            if (t == "Figure" || t == "Formula") && DotNetText.isNullOrWhiteSpace(element.alt) && DotNetText.isNullOrWhiteSpace(element.actualText) {
                add(t == "Figure" ? "13-004" : "17-002", t == "Figure" ? "7.3" : "7.7", Self.place(element), PdfUaText.noAlt(t))
            }
            if let lang = element.lang, !AccessibilityChecker.isLanguageTag(lang) { add("11-007", "7.2", Self.place(element), PdfUaText.badLanguage(lang)) }
            if t != "Note" { continue }
            if let id = element.id, !id.isEmpty {
                if !notes.insert(OrdinalString(id)).inserted { add("19-004", "7.9", Self.place(element), PdfUaText.noteIdTwice(id)) }
            } else {
                add("19-003", "7.9", Self.place(element), PdfUaText.noteId)
            }
        }
    }

    // 7.1: a type that is not standard leads to one that is, through a role map without loops, and a standard type is not remapped.
    private func checkRoleMap(_ tree: StructureTree, _ elements: [StructElement]) {
        for entry in tree.roleMap.entries.sorted(by: { ordinalPrecedes($0.key, $1.key) }).prefix(Self.maxEntries) {
            if StructureTree.isStandard(entry.key) && !XmlParser.same(entry.key, entry.value) {
                add("02-003", "7.1", PdfAText.catalog, PdfUaText.standardRemapped(entry.key, entry.value))
            }
        }
        var types = Set<OrdinalString>()
        var first = [OrdinalString: StructElement]()
        for entry in tree.roleMap.entries.prefix(Self.maxEntries) { types.insert(OrdinalString(entry.key)) }
        for element in elements {
            let key = OrdinalString(element.type)
            types.insert(key)
            if first[key] == nil { first[key] = element }
        }
        for type in types.map({ $0.text }).sorted(by: ordinalPrecedes) {
            if truncated { break }
            if StructureTree.isStandard(type) { continue }
            if loops(tree, type) {
                add("02-002", "7.1", PdfAText.catalog, PdfUaText.roleMapCircular(type))
            } else if !StructureTree.isStandard(tree.standardType(type)), let element = first[OrdinalString(type)] {
                add("02-001", "7.1", Self.place(element), PdfUaText.notMapped(type))
            }
        }
    }

    // The chain never reaches a standard type or an end: it comes back to a type it met, or runs past 16 steps.
    private func loops(_ tree: StructureTree, _ start: String) -> Bool {
        var type = start
        var met = Set<OrdinalString>()
        while !StructureTree.isStandard(type), let next = tree.roleMap[type] {
            if !met.insert(OrdinalString(type)).inserted || met.count > 16 { return true }
            type = next
        }
        return false
    }

    // 7.5 and 7.6: rows hold cells, sections hold rows, items hold a label and a body.
    private func checkNesting(_ elements: [StructElement], _ type: (StructElement) -> String) {
        for element in elements {
            let t = type(element)
            let parent = element.parent.map(type) ?? ""
            let table = ["THead", "TBody", "TFoot", "TR", "TH", "TD", "Table"].contains(t)
            let list = ["L", "LI", "Lbl", "LBody"].contains(t)
            if !table && !list { continue }
            let checkpoint = table ? "09-004" : "09-005"
            let clause = table ? "7.5" : "7.6"

            let isPlaced: Bool
            switch t {
            case "THead", "TBody", "TFoot": isPlaced = parent == "Table"
            case "TR": isPlaced = parent == "Table" || tableParts.contains(parent)
            case "TH", "TD": isPlaced = parent == "TR"
            case "LI": isPlaced = parent == "L"
            case "Lbl", "LBody": isPlaced = parent == "LI"
            default: isPlaced = true
            }
            if !isPlaced { add(checkpoint, clause, Self.place(element), element.parent == nil ? PdfUaText.misnestedTop(t) : PdfUaText.misnested(t, parent)) }

            let allowed: [String]
            switch t {
            case "Table": allowed = ["Caption", "TR", "THead", "TBody", "TFoot"]
            case "THead", "TBody", "TFoot": allowed = ["TR"]
            case "TR": allowed = ["TH", "TD"]
            case "L": allowed = ["LI", "Caption"]
            case "LI": allowed = ["Lbl", "LBody"]
            default: continue
            }
            for child in element.children {
                let c = type(child)
                if !allowed.contains(c) && !placed.contains(c) { add(checkpoint, clause, Self.place(child), PdfUaText.misnested(c, t)) }
            }
        }
    }

    // 7.4: H1 comes first, a level is not skipped going down, and H is not mixed with numbered headings.
    private func checkHeadings(_ elements: [StructElement], _ type: (StructElement) -> String) {
        var previous = 0
        var plain = false
        var numbered = false
        for element in elements {
            let t = type(element)
            if t == "H" { plain = true }
            let units = Array(t.utf16)
            guard units.count >= 2, units[0] == 0x48, let level = Self.parseLevel(units[1...]) else { continue }
            numbered = true
            if previous == 0 && level != 1 {
                add("14-002", "7.4", Self.place(element), PdfUaText.firstHeading(level))
            } else if level > previous + 1 {
                add("14-003", "7.4", Self.place(element), PdfUaText.headingSkipped(level, previous))
            }
            previous = level
        }
        if plain && numbered { add("14-007", "7.4", PdfAText.catalog, PdfUaText.headingMixed) }
    }

    // int.TryParse with the invariant culture: white space around the digits and one sign are allowed.
    private static func parseLevel(_ units: ArraySlice<UInt16>) -> Int? {
        func space(_ u: UInt16) -> Bool { (u >= 9 && u <= 13) || u == 32 }
        var rest = units
        while let first = rest.first, space(first) { rest = rest.dropFirst() }
        while let last = rest.last, space(last) || last == 0 { rest = rest.dropLast() }
        var negative = false
        if let first = rest.first, first == 0x2B || first == 0x2D {
            negative = first == 0x2D
            rest = rest.dropFirst()
        }
        if rest.isEmpty { return nil }
        var value = 0
        for u in rest {
            guard u >= 0x30 && u <= 0x39 else { return nil }
            value = value * 10 + Int(u - 0x30)
            if value > 1 << 31 { return nil }
        }
        let signed = negative ? -value : value
        return signed >= Int(Int32.min) && signed <= Int(Int32.max) ? signed : nil
    }
}
