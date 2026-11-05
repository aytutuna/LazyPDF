import Foundation

// Twin of windows/LazyPDF.Core/Stamps/StampLayers.cs: the optional content group of a stamp run, tagged with the run's id so
// it can be found again (ISO 32000-1 8.11).

enum StampLayers {
    static func add(_ document: PdfDocument, _ id: Int, _ name: String) throws -> PdfReference {
        let print = PdfDictionary()
        print["PrintState"] = PdfName("ON")
        print["Subtype"] = PdfName("Watermark")
        let view = PdfDictionary()
        view["ViewState"] = PdfName("ON")
        let usage = PdfDictionary()
        usage["Print"] = print
        usage["View"] = view
        let group = PdfDictionary()
        group["Type"] = PdfName("OCG")
        group["Name"] = PdfText.toObject(name)
        group["Usage"] = usage
        group[StampStreams.key] = PdfNumber(id)
        let reference = try document.add(group)

        let properties = ensureDict(document, document.catalog, "OCProperties")
        ensureArray(document, properties, "OCGs").items.append(reference)
        ensureArray(document, ensureDict(document, properties, "D"), "Order").items.append(reference)
        return reference
    }

    static func remove(_ document: PdfDocument, _ id: Int) {
        guard let properties = document.dict(document.catalog, "OCProperties"), let groups = document.array(properties, "OCGs") else { return }
        var mine: [PdfReference] = []
        for case let r as PdfReference in groups.items {
            if let d = document.resolve(r) as? PdfDictionary, document.integer(d, StampStreams.key) == id { mine.append(r) }
        }
        for reference in mine {
            if let at = groups.items.firstIndex(where: { ($0 as? PdfReference) == reference }) { groups.items.remove(at: at) }
            unlist(document, document.dict(properties, "D"), reference)
            document.delete(reference.number)
        }
        if !mine.isEmpty && groups.items.isEmpty { document.catalog.remove("OCProperties") }
    }

    // The configuration names a layer in more places than /Order.
    private static func unlist(_ document: PdfDocument, _ config: PdfDictionary?, _ layer: PdfReference) {
        guard let config else { return }
        var seen = Set<ObjectIdentifier>()
        for key in ["Order", "ON", "OFF", "Locked", "RBGroups"] {
            if let array = document.array(config, key) { strip(document, array, layer, 0, &seen) }
        }
        if let states = document.array(config, "AS") {
            for state in states.items {
                if let d = document.resolve(state) as? PdfDictionary, let groups = document.array(d, "OCGs") {
                    strip(document, groups, layer, 0, &seen)
                }
            }
        }
    }

    // An array that holds itself would otherwise be walked once per way into it.
    private static func strip(_ document: PdfDocument, _ array: PdfArray, _ layer: PdfReference, _ depth: Int,
                              _ seen: inout Set<ObjectIdentifier>) {
        if !seen.insert(ObjectIdentifier(array)).inserted { return }
        array.items.removeAll { ($0 as? PdfReference)?.number == layer.number }
        if depth > 8 { return }
        for item in array.items {
            if let inner = document.resolve(item) as? PdfArray { strip(document, inner, layer, depth + 1, &seen) }
        }
    }

    private static func ensureDict(_ document: PdfDocument, _ parent: PdfDictionary, _ key: String) -> PdfDictionary {
        if let existing = document.dict(parent, key) { return existing }
        let created = PdfDictionary()
        parent[key] = created
        return created
    }

    private static func ensureArray(_ document: PdfDocument, _ parent: PdfDictionary, _ key: String) -> PdfArray {
        if let existing = document.array(parent, key) { return existing }
        let created = PdfArray([])
        parent[key] = created
        return created
    }
}
