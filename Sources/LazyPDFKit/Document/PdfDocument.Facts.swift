import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Twin of windows/LazyPDF.Core/Document/PdfDocument.Facts.cs: facts about the file. Signed, certified and PDF/A
// are as in Lazy Scan's PdfReaderLite.cs.
//
// The C# reads the XMP with XmlReader and XDocument. Here XMLParser does (FoundationXML on Linux), and the file's
// DTD and its undeclared entities are refused before it sees them, as DtdProcessing.Prohibit and the reader's
// own checks do there.

extension PdfDocument {
    private static let maxMetadataSize = 1 << 24
    private static let pdfAIdNamespace = "http://www.aiim.org/pdfa/ns/id/"

    /// The file is signed: its form says signatures exist (/SigFlags bit 1) or the catalog carries signature
    /// permissions (/Perms).
    public var isSigned: Bool {
        if let perms = dict(catalog, "Perms"), perms.count > 0 { return true }
        if let flags = integer(dict(catalog, "AcroForm"), "SigFlags") { return flags & 1 != 0 }
        return false
    }

    /// The file is certified: its catalog's /Perms has a /DocMDP signature. No certification allows adding
    /// pages (ISO 32000-1 12.8.2.2), so viewers show it as no longer valid after.
    public var isCertified: Bool {
        guard let perms = dict(catalog, "Perms") else { return false }
        return resolve(perms["DocMDP"]) != nil
    }

    /// The form has XFA data. Lazy PDF shows the page content and leaves the XFA form alone.
    public var hasXfa: Bool { resolve(dict(catalog, "AcroForm")?["XFA"]) != nil }

    /// The catalog says the file is tagged (/MarkInfo /Marked true).
    public var isTagged: Bool { bool(dict(catalog, "MarkInfo"), "Marked") == true }

    /// The first object of the file holds a /Linearized dictionary (Annex F) whose /L is the length of the file.
    /// An update added after it makes the length differ: the file is still valid but no longer linearized, and
    /// so is a file cut short.
    public var isLinearized: Bool {
        if let known = linearizedKnown { return known }
        let result = (linearizationDictionary()?["L"] as? PdfNumber)?.integer == source.count
        linearizedKnown = result
        return result
    }

    /// The file starts with a linearization dictionary, whether or not an update has been added since.
    var wasLinearized: Bool { linearizationDictionary() != nil }

    /// The PDF/A part its XMP metadata claims (1, 2, 3, 4), or nil when it claims none.
    public var pdfAPart: Int? { pdfAIdentification().part }

    /// The PDF/A conformance level its metadata claims ("A", "B", "U"), or nil.
    public var pdfAConformance: String? { pdfAIdentification().conformance }

    private func linearizationDictionary() -> PdfDictionary? {
        let lexer = PdfLexer(sourceBytes, position: headerVersionEnd)
        do {
            _ = try lexer.readObjectHeader()
            if let dictionary = try lexer.readObject() as? PdfDictionary, dictionary.containsKey("Linearized") { return dictionary }
            return nil
        } catch {
            return nil
        }
    }

    private func pdfAIdentification() -> (part: Int?, conformance: String?) {
        if let known = pdfAKnown { return known }
        var result: (part: Int?, conformance: String?) = (nil, nil)
        // Metadata that cannot be read claims nothing.
        if let metadata = stream(catalog, "Metadata"), let xmp = try? data(metadata, Self.maxMetadataSize) {
            result = Self.readPdfAId(xmp)
        }
        pdfAKnown = result
        return result
    }

    /// pdfaid:part and pdfaid:conformance from XMP, as attributes or elements.
    static func readPdfAId(_ xmp: [UInt8]) -> (part: Int?, conformance: String?) {
        let start = xmp.indexOf("<x:xmpmeta".keywordBytes) ?? xmp.indexOf("<rdf:RDF".keywordBytes)
        let closing = "</x:xmpmeta>".keywordBytes
        var slice = xmp
        if let start {
            if let end = xmp.lastIndexOf(closing), end > start {
                slice = Array(xmp[start..<end + closing.count])
            } else {
                slice = Array(xmp[start...])
            }
        }
        let xml = String(decoding: slice, as: UTF8.self)
        guard let reader = XmpIdReader.read(xml) else { return (nil, nil) }

        var part: String?
        var conformance: String?
        for element in reader.elements {
            if part == nil { part = element.part }
            if conformance == nil { conformance = element.conformance }
            if element.namespace == pdfAIdNamespace && element.local == "part" && part == nil { part = reader.text(of: element) }
            if element.namespace == pdfAIdNamespace && element.local == "conformance" && conformance == nil { conformance = reader.text(of: element) }
        }
        let number = part.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.map { Int($0) }
        let trimmed = conformance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let level: String? = trimmed.isEmpty ? nil : trimmed.uppercased()
        return (number, number == nil ? nil : level)
    }
}

/// The elements of an XMP packet in document order, with the pdfaid attributes each carries and where its
/// text sits in the packet's text, which is all `readPdfAId` asks of a document.
private final class XmpIdReader: NSObject, XMLParserDelegate {
    struct Element {
        var namespace = ""
        var local = ""
        var part: String?
        var conformance: String?
        var textStart = 0
        var textEnd = 0
    }

    private(set) var elements: [Element] = []
    private var scopes: [[String: String]] = [["xml": "http://www.w3.org/XML/1998/namespace"]]
    private var open: [Int] = []
    private var characters: [UInt16] = []
    private var failed = false

    static func read(_ xml: String) -> XmpIdReader? {
        if hasDoctypeOrUndeclaredEntity(xml) { return nil }
        let parser = XMLParser(data: Data(xml.utf8))
        let reader = XmpIdReader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !reader.failed ? reader : nil
    }

    /// A DOCTYPE, or an entity other than the five XML defines and the numeric ones: with no DTD there is no way to
    /// declare it. Comments, CDATA sections and processing instructions are skipped, as a reader that refuses a DTD
    /// still accepts them.
    private static func hasDoctypeOrUndeclaredEntity(_ xml: String) -> Bool {
        let known: Set<String> = ["amp", "lt", "gt", "quot", "apos"]
        let bytes = Array(xml.utf8)
        func starts(_ at: Int, _ text: String) -> Bool {
            let pattern = Array(text.utf8)
            return at + pattern.count <= bytes.count && Array(bytes[at..<at + pattern.count]) == pattern
        }
        func skip(_ at: Int, past end: String) -> Int {
            bytes.indexOf(Array(end.utf8), from: at).map { $0 + end.utf8.count } ?? bytes.count
        }
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "<") {
                if starts(i, "<!--") {
                    i = skip(i + 4, past: "-->")
                } else if starts(i, "<![CDATA[") {
                    i = skip(i + 9, past: "]]>")
                } else if starts(i, "<?") {
                    i = skip(i + 2, past: "?>")
                } else if starts(i, "<!DOCTYPE") {
                    return true
                } else {
                    i += 1
                }
            } else if bytes[i] == UInt8(ascii: "&") {
                var end = i + 1
                while end < bytes.count && end - i <= 32 && bytes[end] != UInt8(ascii: ";") && bytes[end] != UInt8(ascii: "&") { end += 1 }
                if end < bytes.count && bytes[end] == UInt8(ascii: ";") {
                    let name = String(decoding: bytes[(i + 1)..<end], as: UTF8.self)
                    if !name.hasPrefix("#") && !known.contains(name) { return true }
                    i = end + 1
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return false
    }

    func text(of element: Element) -> String {
        String(decoding: characters[element.textStart..<element.textEnd], as: UTF16.self)
    }

    private static func split(_ name: String) -> (prefix: String?, local: String) {
        guard let colon = name.firstIndex(of: ":") else { return (nil, name) }
        return (String(name[..<colon]), String(name[name.index(after: colon)...]))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        var scope = scopes[scopes.count - 1]
        for (key, value) in attributeDict {
            if key == "xmlns" {
                scope[""] = value
            } else if key.hasPrefix("xmlns:") {
                scope[String(key.dropFirst(6))] = value
            }
        }
        scopes.append(scope)
        let name = Self.split(elementName)
        var element = Element(textStart: characters.count)
        element.local = name.local
        if let uri = scope[name.prefix ?? ""] {
            element.namespace = uri
        } else if name.prefix != nil {
            failed = true
        }
        for (key, value) in attributeDict where key != "xmlns" && !key.hasPrefix("xmlns:") {
            let attribute = Self.split(key)
            guard let prefix = attribute.prefix else { continue }
            guard let uri = scope[prefix] else {
                failed = true
                continue
            }
            if uri == "http://www.aiim.org/pdfa/ns/id/" {
                if attribute.local == "part" { element.part = value }
                if attribute.local == "conformance" { element.conformance = value }
            }
        }
        open.append(elements.count)
        elements.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let index = open.popLast() { elements[index].textEnd = characters.count }
        scopes.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters.append(contentsOf: string.utf16)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        characters.append(contentsOf: String(decoding: CDATABlock, as: UTF8.self).utf16)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}
