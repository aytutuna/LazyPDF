import Foundation

// Twin of windows/LazyPDF.Core/Structure/Metadata.cs: the descriptive metadata of a document (ISO 32000-1 14.3): the
// /Info dictionary and, kept in step with it, the XMP packet.
//
// `custom` is an `OrderedStrings` where the C# has a Dictionary: .NET enumerates a Dictionary in insertion order and
// `write` puts the entries into /Info in that order, so a hash order would change the saved bytes from run to run.

/// String keys to string values in the order they were added; the part of a Dictionary this layer uses.
public struct OrderedStrings: Equatable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var entries: [(key: String, value: String)] = []

    public init() {}

    public init(dictionaryLiteral elements: (String, String)...) {
        for (key, value) in elements { self[key] = value }
    }

    public var keys: [String] { entries.map { $0.key } }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: String) -> String? {
        get { entries.first { $0.key == key }?.value }
        set {
            let at = entries.firstIndex { $0.key == key }
            if let value = newValue {
                if let at {
                    entries[at].value = value
                } else {
                    entries.append((key, value))
                }
            } else if let at {
                entries.remove(at: at)
            }
        }
    }

    public func makeIterator() -> IndexingIterator<[(key: String, value: String)]> {
        entries.makeIterator()
    }

    // Equal when they hold the same pairs, as two dictionaries are.
    public static func == (a: OrderedStrings, b: OrderedStrings) -> Bool {
        a.count == b.count && a.entries.allSatisfy { b[$0.key] == $0.value }
    }
}

/// `custom` holds the /Info entries with other keys whose value is a string. `xmpUnreadable` is true when the file has an
/// XMP packet that could not be read.
public struct DocumentMetadata: Equatable {
    private static let standard = ["Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate", "Trapped"]

    public var title: String?
    public var author: String?
    public var subject: String?
    public var keywords: String?
    public var creator: String?
    public var producer: String?
    public var created: DateTimeOffset?
    public var modified: DateTimeOffset?
    public var custom: OrderedStrings
    public var xmpUnreadable: Bool

    public init(_ title: String?, _ author: String?, _ subject: String?, _ keywords: String?, _ creator: String?, _ producer: String?,
                _ created: DateTimeOffset?, _ modified: DateTimeOffset?, _ custom: OrderedStrings, _ xmpUnreadable: Bool = false) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
        self.creator = creator
        self.producer = producer
        self.created = created
        self.modified = modified
        self.custom = custom
        self.xmpUnreadable = xmpUnreadable
    }

    /// The metadata from /Info; what it lacks is taken from the XMP packet. Dates without a zone count as UTC.
    public static func read(_ document: PdfDocument) -> DocumentMetadata {
        let info = document.info
        let xmp = XmpPacket.load(document)
        func text(_ key: String, _ ns: String, _ name: String) -> String? {
            PdfText.read(document, info, key) ?? xmp?.get(ns, name)
        }
        func date(_ key: String, _ name: String) -> DateTimeOffset? {
            PdfDate.parse(PdfText.read(document, info, key)) ?? PdfDate.parseXmp(xmp?.get(XmpPacket.xmp, name))
        }

        var found: [String: String] = [:]
        for entry in (info?.entries ?? []).prefix(10_000) {
            guard !standard.contains(entry.key), let value = document.resolve(entry.value) as? PdfString else { continue }
            found[entry.key] = PdfText.decode(value.bytes)
        }
        var custom = OrderedStrings()
        // SortedDictionary with StringComparer.Ordinal: UTF-16 code units.
        for key in found.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) { custom[key] = found[key] }
        return DocumentMetadata(
            text("Title", XmpPacket.dc, "title"), text("Author", XmpPacket.dc, "creator"), text("Subject", XmpPacket.dc, "description"),
            text("Keywords", XmpPacket.pdf, "Keywords"), text("Creator", XmpPacket.xmp, "CreatorTool"), text("Producer", XmpPacket.pdf, "Producer"),
            date("CreationDate", "CreateDate"), date("ModDate", "ModifyDate"), custom,
            xmp == nil && XmpPacket.isPresent(document))
    }

    /// Stores the metadata: /Info is made if the file has none, a key set to nil or empty is taken out, and an /Info entry
    /// that is not here and not a string stays. The XMP packet is updated when the file has one that can be read and is
    /// not behind a Crypt filter; none is made.
    public func write(_ document: PdfDocument) throws {
        let info = document.info ?? PdfDictionary()
        if document.info == nil { document.trailer["Info"] = try document.add(info) }
        let before = Self.read(document).custom

        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty {
                info[key] = PdfText.toObject(value)
            } else {
                info.remove(key)
            }
        }
        put("Title", title)
        put("Author", author)
        put("Subject", subject)
        put("Keywords", keywords)
        put("Creator", creator)
        put("Producer", producer)
        // A date Read could not parse is not Created, but it is still in the file and stays.
        if created != nil || PdfDate.parse(PdfText.read(document, info, "CreationDate")) != nil || !info.containsKey("CreationDate") {
            put("CreationDate", created.map { PdfDate.format($0) })
        }
        if modified != nil || PdfDate.parse(PdfText.read(document, info, "ModDate")) != nil || !info.containsKey("ModDate") {
            put("ModDate", modified.map { PdfDate.format($0) })
        }
        let wanted = custom.entries.filter { !$0.key.isEmpty && !Self.standard.contains($0.key) }
        for key in before.keys where !wanted.contains(where: { $0.key == key }) { info.remove(key) }
        for entry in wanted { put(entry.key, entry.value) }

        var customKeys: [String] = []
        for key in before.keys + wanted.map({ $0.key }) where !customKeys.contains(key) { customKeys.append(key) }
        writeXmp(document, customKeys)
    }

    private func writeXmp(_ document: PdfDocument, _ customKeys: [String]) {
        guard let stream = document.stream(document.catalog, "Metadata"), !Self.hasCryptFilter(document, stream) else { return }
        guard let xmp = XmpPacket.load(document) else { return }

        func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }
        xmp.setAlt(XmpPacket.dc, "dc", "title", nonEmpty(title))
        xmp.setSeq(XmpPacket.dc, "dc", "creator", nonEmpty(author))
        xmp.setAlt(XmpPacket.dc, "dc", "description", nonEmpty(subject))
        xmp.set(XmpPacket.pdf, "pdf", "Keywords", nonEmpty(keywords))
        xmp.setBag(XmpPacket.dc, "dc", "subject", Self.split(keywords ?? ""))
        xmp.set(XmpPacket.pdf, "pdf", "Producer", nonEmpty(producer))
        xmp.set(XmpPacket.xmp, "xmp", "CreatorTool", nonEmpty(creator))
        xmp.set(XmpPacket.xmp, "xmp", "CreateDate", created.map { PdfDate.formatXmp($0) })
        xmp.set(XmpPacket.xmp, "xmp", "ModifyDate", modified.map { PdfDate.formatXmp($0) })
        if let md = modified, xmp.has(XmpPacket.xmp, "MetadataDate") { xmp.set(XmpPacket.xmp, "xmp", "MetadataDate", PdfDate.formatXmp(md)) }
        for key in customKeys where XmlSyntax.isNCName(key) {
            let value = custom[key]
            xmp.set(XmpPacket.pdfx, "pdfx", key, (value?.isEmpty ?? true) ? nil : value)
        }

        stream.data = xmp.toBytes()
        stream.dictionary.remove("Filter")
        stream.dictionary.remove("DecodeParms")
    }

    // Split([',', ';'], TrimEntries | RemoveEmptyEntries).
    private static func split(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { PdfDate.trimmed(String(String.UnicodeScalarView($0))) }
            .filter { !$0.isEmpty }
    }

    private static func hasCryptFilter(_ document: PdfDocument, _ stream: PdfStream) -> Bool {
        switch document.resolve(stream.dictionary["Filter"]) {
        case let n as PdfName: return n.value == "Crypt"
        case let a as PdfArray: return a.items.contains { (document.resolve($0) as? PdfName)?.value == "Crypt" }
        default: return false
        }
    }
}
