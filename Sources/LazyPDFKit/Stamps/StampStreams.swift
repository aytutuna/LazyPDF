import Foundation

// Twin of windows/LazyPDF.Core/Stamps/StampStreams.cs: how a stamp sits in a page's /Contents. Each run adds one stream per
// page carrying a /LazyPDF dictionary (the run's id, kind, label and whether it is behind). A stamp in front of the page is
// kept apart from the page's own content by a pair of marked streams around it, built from how unbalanced the content is:
// the first opens as many q as the content may pop and the second closes what it leaves open, so the stamp starts and ends
// in a clean graphics state whatever the page does (ISO 32000-1 8.4.2). Stamps behind the page need none, they close
// themselves.

enum StampStreams {
    static let key = "LazyPDF"
    private static let maxDepth = 1000

    static func prefix(_ id: Int) -> String { "LPS\(id)_" }
    static func fontName(_ id: Int) -> String { prefix(id) + "F" }
    static func imageName(_ id: Int) -> String { prefix(id) + "I" }
    static func stateName(_ id: Int) -> String { prefix(id) + "G" }
    static func layerResourceName(_ id: Int) -> String { prefix(id) + "P" }

    /// The run id in a marker; one outside the range of an int is not one this code wrote, and is left alone.
    static func idOf(_ document: PdfDocument, _ marker: PdfDictionary) -> Int? {
        document.integer(marker, "Id").flatMap { Int32(exactly: $0) }.map { Int($0) }
    }

    /// An id above every one in use, or the lowest free one when there is none above.
    static func spare(_ used: Set<Int>) -> Int {
        let top = used.max() ?? 0
        if top < Int(Int32.max) { return top + 1 }
        var id = 1
        while used.contains(id) { id += 1 }
        return id
    }

    struct Found {
        let id: Int
        let kind: StampKind
        let label: String?
        let behind: Bool
    }

    static func contents(_ document: PdfDocument, _ page: PdfPage) -> [PdfObject] {
        guard let value = page.dictionary["Contents"] else { return [] }
        switch document.resolve(value) {
        case is PdfStream: return [value]
        case let array as PdfArray: return array.items
        default: return []
        }
    }

    private static func markerOf(_ document: PdfDocument, _ item: PdfObject) -> PdfDictionary? {
        guard let stream = document.resolve(item) as? PdfStream else { return nil }
        return document.dict(stream.dictionary, key)
    }

    /// The runs on the page in content order.
    static func scan(_ document: PdfDocument, _ page: PdfPage) -> [Found] {
        var found: [Found] = []
        for item in contents(document, page) {
            guard let marker = markerOf(document, item), let id = idOf(document, marker) else { continue }
            let kind = document.name(marker, "Kind").flatMap { name in StampKind.allCases.first { $0.name == name } } ?? .watermark
            let label = (document.resolve(marker["Label"]) as? PdfString).map { PdfText.decode($0.bytes) }
            found.append(Found(id: id, kind: kind, label: label, behind: document.bool(marker, "Back") == true))
        }
        return found
    }

    static func add(_ document: PdfDocument, _ page: PdfPage, _ content: [UInt8], _ id: Int, _ kind: StampKind, _ label: String?,
                    _ behind: Bool) throws {
        let marker = PdfDictionary()
        marker["Id"] = PdfNumber(id)
        marker["Kind"] = PdfName(kind.name)
        if let label, !label.isEmpty { marker["Label"] = PdfText.toObject(label) }
        if behind { marker["Back"] = PdfBoolean(true) }
        let reference = try addStream(document, content, marker)

        var items = contents(document, page)
        if behind {
            items.insert(reference, at: leadingBack(document, items))
        } else {
            if !items.contains(where: { markerOf(document, $0)?["Wrap"] != nil }) { try wrap(document, page, &items) }
            items.append(reference)
        }
        page.dictionary["Contents"] = PdfArray(items)
    }

    /// Takes the run off the page; returns false when it was not there.
    static func remove(_ document: PdfDocument, _ page: PdfPage, _ id: Int, _ uses: inout [Int: Int]) -> Bool {
        var items = contents(document, page)
        let before = items.count
        items.removeAll { drop(document, $0, id, &uses) }
        if items.count == before { return false }
        // Without a stamp in front the wrapper has nothing to keep apart.
        let front = items.contains { item in
            guard let m = markerOf(document, item) else { return false }
            return idOf(document, m) != nil && document.bool(m, "Back") != true
        }
        if !front { items.removeAll { drop(document, $0, nil, &uses) } }
        page.dictionary["Contents"] = PdfArray(items)
        return true
    }

    /// Deletes the stream when it belongs to the run (the wrapper when `id` is nil).
    private static func drop(_ document: PdfDocument, _ item: PdfObject, _ id: Int?, _ uses: inout [Int: Int]) -> Bool {
        guard let marker = markerOf(document, item), let reference = item as? PdfReference else { return false }
        let mine = id == nil ? marker["Wrap"] != nil : idOf(document, marker) == id
        // A duplicated page shares its stamp streams: they are freed with the last page that lists them.
        if !mine { return false }
        let left = (uses[reference.number] ?? 1) - 1
        if left <= 0 {
            document.delete(reference.number)
        } else {
            uses[reference.number] = left
        }
        return true
    }

    /// How many pages list each stamp stream.
    static func countUses(_ document: PdfDocument) -> [Int: Int] {
        var uses: [Int: Int] = [:]
        for page in document.pages {
            var seen = Set<Int>()
            for case let item as PdfReference in contents(document, page) where seen.insert(item.number).inserted {
                if markerOf(document, item) != nil { uses[item.number, default: 0] += 1 }
            }
        }
        return uses
    }

    static func removeResources(_ document: PdfDocument, _ page: PdfPage, _ id: Int) {
        guard let resources = document.dict(page.dictionary, "Resources") else { return }
        let start = prefix(id)
        for category in ["Font", "XObject", "ExtGState", "Properties"] {
            guard let entries = document.dict(resources, category) else { continue }
            for name in entries.entries.map({ $0.key }) where name.hasPrefix(start) { entries.remove(name) }
        }
    }

    static func register(_ document: PdfDocument, _ resources: PdfDictionary, _ category: String, _ name: String, _ value: PdfObject) {
        let entries: PdfDictionary
        if let existing = document.dict(resources, category) {
            entries = existing
        } else {
            entries = PdfDictionary()
            resources[category] = entries
        }
        entries[name] = value
    }

    private static func addStream(_ document: PdfDocument, _ content: [UInt8], _ marker: PdfDictionary) throws -> PdfReference {
        let dictionary = PdfDictionary()
        dictionary[key] = marker
        return try document.add(PdfStream(dictionary, data: content))
    }

    private static func leadingBack(_ document: PdfDocument, _ items: [PdfObject]) -> Int {
        var n = 0
        while n < items.count, let m = markerOf(document, items[n]), document.bool(m, "Back") == true { n += 1 }
        return n
    }

    private static func wrap(_ document: PdfDocument, _ page: PdfPage, _ items: inout [PdfObject]) throws {
        var depth = 0, lowest = 0, marked = 0
        var text = false
        for operation in ContentParser.parse(page.contents()) {
            switch operation.operator {
            case "q": depth += 1
            case "Q":
                depth -= 1
                lowest = Swift.min(lowest, depth)
            case "BT": text = true
            case "ET": text = false
            case "BMC", "BDC": marked += 1
            case "EMC": marked = Swift.max(0, marked - 1)
            default: break
            }
        }
        // A Q the content has no q for pops ours, so open enough that none of them can run dry.
        let opened = Swift.min(Swift.max(1 - lowest, 1), maxDepth)
        let close = ContentWriter()
        if text { close.endText() }
        for _ in 0..<Swift.min(marked, maxDepth) { close.endMarked() }
        for _ in 0..<Swift.min(Swift.max(opened + depth, 0), maxDepth) { close.restore() }

        let open = ContentWriter()
        for _ in 0..<opened { open.save() }
        items.insert(try addStream(document, open.toArray(), wrapMarker("Open")), at: leadingBack(document, items))
        items.append(try addStream(document, close.toArray(), wrapMarker("Close")))
    }

    private static func wrapMarker(_ part: String) -> PdfDictionary {
        let marker = PdfDictionary()
        marker["Wrap"] = PdfName(part)
        return marker
    }
}
