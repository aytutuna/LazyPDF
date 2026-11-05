import Foundation

// Twin of windows/LazyPDF.Core/Optimize/SanitizeData.cs: what a file carries besides what it shows: attachments,
// comments, entered form data, descriptive metadata, application data, web capture data and file names. Each method
// counts what it finds and, when asked, takes it out.

enum SanitizeData {
    private static let maxParents = 64

    // Annotations that are the reader's own marks; links, widgets and media belong to the page.
    private static let notComments: Set<String> = ["Link", "Widget", "Screen", "Movie", "3D", "RichMedia", "PrinterMark", "TrapNet", "Watermark", "FileAttachment"]

    static func embeddedFiles(_ document: PdfDocument, _ remove: Bool) -> Int {
        let listed = PdfAttachments.list(document).count
        let all = PdfGraph.allDictionaries(document)
        let specs = all.filter { $0.containsKey("EF") || $0.containsKey("RF") }.count
        if remove {
            document.dict(document.catalog, "Names")?.remove("EmbeddedFiles")
            removeAnnotations(document) { document.name($0, "Subtype") == "FileAttachment" }
            for dictionary in all {
                dictionary.remove("EF")
                dictionary.remove("RF")
                dictionary.remove("AF")
                if dictionary === document.catalog { dictionary.remove("Collection") }
            }
        }
        return max(listed, specs)
    }

    static func comments(_ document: PdfDocument, _ remove: Bool) -> Int {
        var found = 0
        for page in document.pages {
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            for item in annots.items {
                if let a = document.resolve(item) as? PdfDictionary, isComment(document, a), document.name(a, "Subtype") != "Popup" { found += 1 }
            }
        }
        if remove { removeAnnotations(document) { isComment(document, $0) } }
        return found
    }

    private static func isComment(_ document: PdfDocument, _ annotation: PdfDictionary) -> Bool {
        guard let type = document.name(annotation, "Subtype") else { return false }
        return !notComments.contains(type)
    }

    // The structure tree names annotations too (OBJR), and the rewrite keeps whatever is reachable.
    static func removeAnnotations(_ document: PdfDocument, _ remove: (PdfDictionary) -> Bool) {
        var gone = Set<Int>()
        for page in document.pages {
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            annots.items.removeAll { item in
                guard let a = document.resolve(item) as? PdfDictionary, remove(a) else { return false }
                if let reference = item as? PdfReference { gone.insert(reference.number) }
                return true
            }
            if annots.items.isEmpty { page.dictionary.remove("Annots") }
        }
        PdfGraph.detach(document, gone)
        if !gone.isEmpty { dropEmptyObjectRefs(document) }
    }

    // Detach takes the /Obj out of an OBJR but leaves the dictionary, which is invalid without it (14.7.4.3).
    private static func dropEmptyObjectRefs(_ document: PdfDocument) {
        func empty(_ item: PdfObject?) -> Bool {
            guard let d = document.resolve(item) as? PdfDictionary else { return false }
            return document.name(d, "Type") == "OBJR" && !d.containsKey("Obj")
        }
        for element in PdfGraph.allDictionaries(document) {
            guard let kids = element["K"] else { continue }
            if let list = document.resolve(kids) as? PdfArray {
                list.items.removeAll { empty($0) }
                if list.items.isEmpty { element.remove("K") }
            } else if empty(kids) {
                element.remove("K")
            }
        }
    }

    static func formData(_ document: PdfDocument, _ remove: Bool) throws -> Int {
        let form = PdfForm.read(document)
        let entered = form.fields.filter { field in
            field.kind != .signature && field.kind != .pushButton && !(field.value ?? "").isEmpty && field.value != "Off"
        }
        if !remove { return entered.count }
        for field in form.fields {
            field.dictionary.remove("DV")
            for parent in parents(document, field.dictionary) { parent.remove("DV") }
        }
        form.refresh()
        do {
            try form.reset()
        } catch let error where error is PdfReadException || error is InvalidOperationException {
            for field in entered { blank(document, field.dictionary) }
        }
        // Reset and Blank work down from the field; a value a parent passes on to its kids is only reachable from here.
        for field in form.fields {
            for parent in parents(document, field.dictionary) { parent.remove("V") }
        }
        document.dict(document.catalog, "AcroForm")?.remove("XFA")
        return entered.count
    }

    private static func parents(_ document: PdfDocument, _ node: PdfDictionary) -> [PdfDictionary] {
        var found: [PdfDictionary] = []
        var up = document.dict(node, "Parent")
        var depth = 0
        while let current = up, depth < maxParents {
            found.append(current)
            up = document.dict(current, "Parent")
            depth += 1
        }
        return found
    }

    // The value also sits in the appearance, the rich text and the selected state or index of a widget, which may be a kid of the field.
    static func blank(_ document: PdfDocument, _ field: PdfDictionary, _ depth: Int = 0) {
        field.remove("V")
        field.remove("RV")
        field.remove("AP")
        field.remove("AS")
        field.remove("I")
        guard depth < 8, let kids = document.array(field, "Kids") else { return }
        for kid in kids.items {
            if let widget = document.resolve(kid) as? PdfDictionary, !widget.containsKey("T") { blank(document, widget, depth + 1) }
        }
    }

    static func metadata(_ document: PdfDocument, _ remove: Bool) -> Int {
        var count = document.trailer.containsKey("Info") ? 1 : 0
        for dictionary in PdfGraph.allDictionaries(document) {
            for key in ["Metadata", "LastModified"] {
                if !dictionary.containsKey(key) { continue }
                count += 1
                if remove { dictionary.remove(key) }
            }
        }
        if remove { document.trailer.remove("Info") }
        return count
    }

    static func pieceInfo(_ document: PdfDocument, _ remove: Bool) -> Int {
        var count = 0
        for dictionary in PdfGraph.allDictionaries(document) {
            if !dictionary.containsKey("PieceInfo") { continue }
            count += 1
            if remove { dictionary.remove("PieceInfo") }
        }
        return count
    }

    static func thumbnails(_ document: PdfDocument, _ remove: Bool) -> Int {
        let count = document.pages.filter { $0.dictionary.containsKey("Thumb") }.count
        if remove { _ = OptimizeStrip.thumbnails(document) }
        return count
    }

    // Web capture keeps its own indexes of pages and addresses.
    static func searchIndexes(_ document: PdfDocument, _ remove: Bool) -> Int {
        var count = 0
        func take(_ owner: PdfDictionary?, _ key: String) {
            guard let owner, owner.containsKey(key) else { return }
            count += 1
            if remove { owner.remove(key) }
        }
        take(document.catalog, "SpiderInfo")
        let names = document.dict(document.catalog, "Names")
        take(names, "IDS")
        take(names, "URLS")
        for page in document.pages where page.dictionary["ID"] is PdfString { take(page.dictionary, "ID") }
        return count
    }

    /// Cuts file specifications down to a bare file name and drops their platform variants.
    static func filePaths(_ document: PdfDocument, _ remove: Bool) -> Int {
        var count = 0
        var seen = Set<ObjectIdentifier>()
        func visit(_ start: PdfDictionary?, window: Bool = false) {
            // A file specification may hold another as its /F (7.11.3).
            var spec = start
            var window = window
            while let current = spec, seen.insert(ObjectIdentifier(current)).inserted {
                var changed = cut(document, current, remove)
                // The parameter string of a Launch commonly carries a path (12.6.4.5).
                if window {
                    for key in ["D", "P"] where current.containsKey(key) {
                        changed = true
                        if remove { current.remove(key) }
                    }
                }
                if changed { count += 1 }
                spec = document.dict(current, "F")
                window = false
            }
        }
        for dictionary in PdfGraph.allDictionaries(document) {
            let launch = SanitizeActions.kind(document, dictionary) == "Launch"
            if launch || document.name(dictionary, "Type") == "Filespec" || dictionary.containsKey("EF") || dictionary.containsKey("RF") { visit(dictionary) }
            if launch { visit(document.dict(dictionary, "Win"), window: true) }
            guard let opi = document.dict(dictionary, "OPI") else { continue }
            visit(document.dict(opi, "1.3"))
            visit(document.dict(opi, "2.0"))
        }
        return count
    }

    // A web address is not a path on this machine, but a file: address is one (7.11.5).
    private static func isAddress(_ text: [UInt16], _ declared: Bool) -> Bool {
        func lower(_ unit: UInt16) -> UInt16 { unit >= 65 && unit <= 90 ? unit + 32 : unit }
        func letter(_ unit: UInt16) -> Bool { (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) }
        if text.count >= 5 && Array(text[0..<5].map(lower)) == Array("file:".utf16) { return false }
        if declared { return true }
        guard let colon = text.firstIndex(of: 0x3A), colon > 1, letter(text[0]) else { return false }
        return text[0..<colon].allSatisfy { letter($0) || ($0 >= 48 && $0 <= 57) || $0 == 0x2B || $0 == 0x2D || $0 == 0x2E }
    }

    private static func cut(_ document: PdfDocument, _ spec: PdfDictionary, _ remove: Bool) -> Bool {
        var changed = false
        let url = document.name(spec, "FS") == "URL"
        for key in ["F", "UF"] {
            guard let text = document.resolve(spec[key]) as? PdfString else { continue }
            let shown = Array(PdfText.decode(text.bytes).utf16)
            if isAddress(shown, url) { continue }
            guard let at = shown.lastIndex(where: { $0 == 0x2F || $0 == 0x5C }) else { continue }
            changed = true
            if remove { text.bytes = PdfText.encode(String(decoding: shown[(at + 1)...], as: UTF16.self)) }
        }
        for key in ["DOS", "Mac", "Unix"] where spec.containsKey(key) {
            changed = true
            if remove { spec.remove(key) }
        }
        return changed
    }
}
