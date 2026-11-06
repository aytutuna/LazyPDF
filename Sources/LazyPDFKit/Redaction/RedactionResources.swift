import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionResources.cs: the /Resources of a page or form, built from what its content
// names instead of cleaned of what was removed.

enum RedactionResources {
    static let lists = ["XObject", "Font", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"]

    /// Gives `owner` resources that hold the entries `walk` found its content to use, however deep (a form without resources of
    /// its own reads the names of the one around it), and nothing else.
    static func rebuild(_ document: PdfDocument, _ owner: PdfDictionary, _ walk: RedactionWalk) {
        let old = document.dict(owner, "Resources")
        let fresh = PdfDictionary()
        for category in lists {
            guard let list = document.dict(old, category) else { continue }
            let kept = PdfDictionary()
            for (name, value) in list.entries where walk.reads.contains(ListName(list, name)) { kept[name] = value }
            if kept.count > 0 { fresh[category] = kept }
        }
        // Names only, written in place: an object behind /ProcSet could be anything.
        if let procedures = document.array(old, "ProcSet") {
            fresh["ProcSet"] = PdfArray(procedures.items.compactMap { document.resolve($0) as? PdfName })
        }
        owner["Resources"] = fresh
    }

    /// Takes out the font selections nothing is shown or painted after, until the font is chosen again or the saved state it
    /// was chosen in is restored. What a removed text left behind would otherwise keep its font, and the font's character map,
    /// in the file.
    static func dropIdleFonts(_ content: [UInt8]) -> [UInt8] {
        let operations = ContentParser.parse(content)
        var idle: [ContentOperation] = []
        for i in 0..<operations.count where operations[i].operator == "Tf" {
            var live = false
            var depth = 0
            var j = i + 1
            while j < operations.count && !live {
                switch operations[j].operator {
                case "Tj", "TJ", "'", "\"", "Do":
                    live = true
                case "Tf" where depth == 0:
                    j = operations.count
                case "q":
                    depth += 1
                case "Q":
                    if depth == 0 { j = operations.count } else { depth -= 1 }
                default:
                    break
                }
                j += 1
            }
            if !live { idle.append(operations[i]) }
        }
        if idle.isEmpty { return content }
        var kept: [UInt8] = []
        var at = 0
        for op in idle {
            if op.start > at { kept.append(contentsOf: content[at..<op.start]) }
            at = max(at, op.end)
        }
        if at < content.count { kept.append(contentsOf: content[at...]) }
        return kept
    }

    /// The content streams of the page, in order.
    static func contents(_ document: PdfDocument, _ page: PdfPage) -> [PdfStream] {
        let contents = document.resolve(page.dictionary["Contents"])
        let items: [PdfObject] = (contents as? PdfArray)?.items ?? [contents ?? PdfNull.instance]
        return items.compactMap { document.resolve($0) as? PdfStream }
    }
}
