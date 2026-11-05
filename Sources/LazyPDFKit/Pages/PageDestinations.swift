import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageDestinations.cs: which page a destination points at, and taking named
// destinations out when pages go. The tables themselves are read and written by Structure.

enum PageDestinations {
    /// The page an explicit destination (an array, or a dictionary with /D) points at; nil for anything else, including a
    /// page number of a remote file.
    static func pageOf(_ document: PdfDocument, _ destination: PdfObject?) -> PdfReference? {
        var value = document.resolve(destination)
        if let dictionary = value as? PdfDictionary { value = document.resolve(dictionary["D"]) }
        if let array = value as? PdfArray, let page = array.items.first as? PdfReference { return page }
        return nil
    }

    /// The destination a name or string stands for, from the catalog's /Dests or the /Names tree; nil when there is none.
    static func lookup(_ document: PdfDocument, _ names: DestContext, _ key: PdfObject?) -> PdfObject? {
        switch document.resolve(key) {
        case let name as PdfName: return names.lookUp(name.value)
        case let text as PdfString: return names.lookUp(Latin1.string(text.bytes))
        default: return nil
        }
    }

    /// The page a /Dest value points at, a name resolved through the document's tables.
    static func pageOfAny(_ document: PdfDocument, _ names: DestContext, _ destination: PdfObject?) -> PdfReference? {
        let resolved = document.resolve(destination)
        if resolved is PdfName || resolved is PdfString { return pageOf(document, lookup(document, names, destination)) }
        return pageOf(document, destination)
    }

    /// Takes out every named destination whose value `dead` says is gone.
    static func removeWhere(_ document: PdfDocument, _ dead: (PdfObject?) -> Bool) throws {
        if let dictionary = document.dict(document.catalog, "Dests") {
            var seen = Set<String>()
            for key in dictionary.entries.map({ $0.key }) where seen.insert(key).inserted {
                if dead(dictionary[key]) { dictionary.remove(key) }
            }
        }
        guard let root = document.dict(document.dict(document.catalog, "Names"), "Dests") else { return }
        let entries = PdfNameTree.read(document, root)
        let kept = entries.filter { !dead($0.value) }
        if kept.count != entries.count { _ = try PdfNameTree.write(document, root, kept) }
    }
}
