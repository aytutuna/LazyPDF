import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageImporter.Layers.cs: the layers of the copied pages are listed in the target's
// /OCProperties, hidden ones in /OFF, so that content the source kept off does not turn up visible (ISO 32000-1 8.11.4.3).

extension PageImporter {
    func mergeLayers() {
        if same { return }
        guard let original = source.dict(source.catalog, "OCProperties") else { return }
        let listed = Set((source.array(original, "OCGs")?.items ?? []).compactMap { ($0 as? PdfReference)?.number })
        let config = source.dict(original, "D")
        let baseOff = source.name(config, "BaseState") == "OFF"
        let on = Self.numbers(source, config, "ON")
        let off = Self.numbers(source, config, "OFF")

        for (number, made) in map.entries {
            if !listed.contains(number) || !layersAdded.insert(number).inserted { continue }
            let properties = ensure(target.catalog, "OCProperties")
            ensureArray(properties, "OCGs").items.append(made)
            ensureArray(ensure(properties, "D"), "Order").items.append(made)
            if baseOff ? !on.contains(number) : off.contains(number) { ensureArray(ensure(properties, "D"), "OFF").items.append(made) }
        }
    }

    private static func numbers(_ document: PdfDocument, _ config: PdfDictionary?, _ key: String) -> Set<Int> {
        Set((document.array(config, key)?.items ?? []).compactMap { ($0 as? PdfReference)?.number })
    }

    private func ensure(_ parent: PdfDictionary, _ key: String) -> PdfDictionary {
        if let existing = target.dict(parent, key) { return existing }
        let created = PdfDictionary()
        parent[key] = created
        return created
    }

    private func ensureArray(_ parent: PdfDictionary, _ key: String) -> PdfArray {
        if let existing = target.array(parent, key) { return existing }
        let created = PdfArray([])
        parent[key] = created
        return created
    }
}
