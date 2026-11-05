import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentResources.cs: registering fonts, images and graphics states a new
// piece of content refers to by name.

public enum ContentResources {
    /// The page's own /Resources dictionary, made if the page has none: an inherited one is copied onto the page first
    /// (ISO 32000-1 7.8.3), so adding to it leaves the other pages alone.
    public static func forEdit(_ document: PdfDocument, _ page: PdfPage) -> PdfDictionary {
        if let own = document.dict(page.dictionary, "Resources") { return own }
        let resources = page.resources?.copy() ?? PdfDictionary()
        page.dictionary["Resources"] = resources
        return resources
    }

    /// Puts `value` in the `category` (Font, XObject, ExtGState...) under a name starting with `prefix` that is not in
    /// use, and returns the name.
    public static func add(_ document: PdfDocument, _ resources: PdfDictionary, _ category: String, _ value: PdfObject, _ prefix: String) -> String {
        let entries: PdfDictionary
        if let existing = document.dict(resources, category) {
            entries = existing
        } else {
            entries = PdfDictionary()
            resources[category] = entries
        }
        var n = 1
        while true {
            let name = prefix + String(n)
            if !entries.containsKey(name) {
                entries[name] = value
                return name
            }
            n += 1
        }
    }
}
