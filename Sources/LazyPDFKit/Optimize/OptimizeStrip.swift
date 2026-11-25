import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeStrip.cs: page thumbnails and the data other applications keep in a
// file for their own use.

enum OptimizeStrip {
    // Second-class names (ISO 32000-1 Annex E) start with a registered prefix and a separator: a letter, one to nine
    // letters or digits, then an underscore or a colon.
    private static func isPrivateName(_ key: String) -> Bool {
        func alnum(_ c: Unicode.Scalar) -> Bool { (c.value >= 48 && c.value <= 57) || (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) }
        let scalars = Array(key.unicodeScalars.prefix(12))
        guard let first = scalars.first, alnum(first), first.value > 57 else { return false }
        var run = 0
        while 1 + run < scalars.count && alnum(scalars[1 + run]) { run += 1 }
        guard run >= 1 && run <= 9, 1 + run < scalars.count else { return false }
        return scalars[1 + run] == "_" || scalars[1 + run] == ":"
    }

    static func thumbnails(_ document: PdfDocument) -> Int {
        var count = 0
        for page in document.pages where page.dictionary.remove("Thumb") { count += 1 }
        return count
    }

    static func pieceInfo(_ document: PdfDocument) -> Int {
        var count = 0
        for dictionary in PdfGraph.allDictionaries(document) where dictionary.remove("PieceInfo") { count += 1 }
        return count
    }

    /// Removes /LastModified and the keys with second-class names from the catalog, the pages and the streams that are forms or images.
    static func privateData(_ document: PdfDocument) -> Int {
        var count = 0
        for (_, value) in PdfGraph.objects(document) {
            guard let dictionary = (value as? PdfDictionary) ?? (value as? PdfStream)?.dictionary else { continue }
            if !(isCarrier(document, dictionary) || dictionary === document.catalog) { continue }
            for (key, _) in dictionary.entries {
                if key == "LastModified" || (isPrivateName(key) && !key.hasPrefix("GTS_")) {
                    dictionary.remove(key)
                    count += 1
                }
            }
        }
        return count
    }

    private static func isCarrier(_ document: PdfDocument, _ dictionary: PdfDictionary) -> Bool {
        if document.name(dictionary, "Type") == "Page" { return true }
        let subtype = document.name(dictionary, "Subtype")
        return subtype == "Form" || subtype == "Image"
    }
}
