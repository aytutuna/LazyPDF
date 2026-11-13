import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PdfUaChecker.Annotations.cs: annotations (ISO 14289-1 7.18), in the tree under the
// right type, with a description for a reader.

extension PdfUaChecker {
    func checkAnnotations() {
        var owners: [Int: StructElement] = [:]
        for element in tree?.elements ?? [] {
            for case let target as StructObject in element.kids where owners[target.target.number] == nil { owners[target.target.number] = element }
        }

        var budget = 50_000
        for page in document.pages {
            guard let annotations = document.array(page.dictionary, "Annots"), !annotations.items.isEmpty else { continue }
            if document.name(page.dictionary, "Tabs") != "S" { add("28-006", "7.18.3", PdfAText.pageName(page.index + 1), PdfUaText.tabOrder) }
            var i = 0
            while i < annotations.items.count {
                budget -= 1
                if budget < 0 { break }
                defer { i += 1 }
                guard let annotation = document.resolve(annotations.items[i]) as? PdfDictionary else { continue }
                guard let subtype = document.name(annotation, "Subtype"), !["Popup", "PrinterMark"].contains(subtype) else { continue }
                let place = PdfAText.annotationName(page.index + 1, i + 1)
                if subtype == "TrapNet" {
                    add("28-007", "7.18.2", place, PdfUaText.trapNet)
                    continue
                }
                let owner = (annotations.items[i] as? PdfReference).flatMap { owners[$0.number] }
                checkAnnotation(annotation, subtype, place, owner)
            }
        }
    }

    private func checkAnnotation(_ annotation: PdfDictionary, _ subtype: String, _ place: String, _ owner: StructElement?) {
        let expected: String
        switch subtype {
        case "Widget": expected = "Form"
        case "Link": expected = "Link"
        default: expected = "Annot"
        }
        if let tree {
            if let owner {
                if tree.standardType(owner.type) != expected {
                    add("28-003", "7.18.1", place, PdfUaText.annotationTag(subtype, expected, tree.standardType(owner.type)))
                }
            } else {
                add("28-002", "7.18.1", place, PdfUaText.annotationUntagged(subtype))
            }
        }
        // The structure element's /Alt stands in for the missing key, except on a Link, whose /Contents 7.18.5 requires itself.
        let described = !DotNetText.isNullOrWhiteSpace(owner?.alt)
        if subtype == "Widget" {
            if !described && !hasTooltip(annotation) { add("28-005", "7.18.4", place, PdfUaText.widgetTooltip) }
        } else if DotNetText.isNullOrWhiteSpace(PdfText.read(document, annotation, "Contents")) && (subtype == "Link" || !described) {
            add("28-004", subtype == "Link" ? "7.18.5" : "7.18.1", place, PdfUaText.annotationContents(subtype))
        }
        if subtype == "FileAttachment" { checkFileSpec(annotation["FS"]) }
    }

    // A widget takes /TU from the field it belongs to.
    private func hasTooltip(_ widget: PdfDictionary) -> Bool {
        var field: PdfDictionary? = widget
        var hops = 0
        while hops < 32, let current = field {
            if !DotNetText.isNullOrWhiteSpace(PdfText.read(document, current, "TU")) { return true }
            field = document.dict(current, "Parent")
            hops += 1
        }
        return false
    }
}
