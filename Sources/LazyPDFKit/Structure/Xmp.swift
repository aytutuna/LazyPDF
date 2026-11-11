import Foundation

// Twin of windows/LazyPDF.Core/Structure/Xmp.cs: the XMP packet of a document (ISO 16684-1) as far as the Info
// dictionary has a counterpart. The metadata is the file's, so no DTD and no entity expansion, as in
// PdfDocument.Facts.cs. XmlTree.swift stands in for System.Xml.Linq.

final class XmpPacket {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let pdf = "http://ns.adobe.com/pdf/1.3/"
    static let pdfx = "http://ns.adobe.com/pdfx/1.3/"

    private static let maxSize = 1 << 24

    private let document: XmlDocument
    private let rdfElement: XmlElement

    private init(_ document: XmlDocument, _ rdf: XmlElement) {
        self.document = document
        rdfElement = rdf
    }

    static func isPresent(_ document: PdfDocument) -> Bool { document.stream(document.catalog, "Metadata") != nil }

    /// The packet in the catalog's /Metadata, or nil when there is none, it is not well-formed, or it has no rdf:RDF.
    static func load(_ document: PdfDocument) -> XmpPacket? {
        guard let stream = document.stream(document.catalog, "Metadata") else { return nil }
        guard let bytes = try? document.data(stream), bytes.count <= maxSize else { return nil }
        guard let xml = XmlDocument.parse(bytes), let rdf = xml.firstDescendant(XmlName(Self.rdf, "RDF")) else { return nil }
        return XmpPacket(xml, rdf)
    }

    /// The text of a property written as an attribute, an element, or the first item of a language alternative or a list.
    func get(_ ns: String, _ name: String) -> String? {
        for description in descriptions() {
            if let attribute = description.attribute(XmlName(ns, name)) { return attribute.value }
            if let element = description.element(XmlName(ns, name)) {
                let text = (element.firstDescendant(XmlName(Self.rdf, "li")) ?? element).value
                let trimmed = PdfDate.trimmed(text)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    func has(_ ns: String, _ name: String) -> Bool {
        descriptions().contains { $0.attribute(XmlName(ns, name)) != nil || $0.element(XmlName(ns, name)) != nil }
    }

    /// Sets a simple property, or takes it out when `value` is nil.
    func set(_ ns: String, _ prefix: String, _ name: String, _ value: String?) {
        put(ns, prefix, name, value.map { XmlElement(XmlName(ns, name), text: Self.clean($0)) })
    }

    /// A language alternative with one item, x-default.
    func setAlt(_ ns: String, _ prefix: String, _ name: String, _ value: String?) {
        put(ns, prefix, name, value.map { value in
            let item = XmlElement(XmlName(Self.rdf, "li"), text: Self.clean(value))
            item.attributes.append(XmlAttribute(XmlName(XmlNamespaces.xml, "lang"), "x-default"))
            return list(ns, name, "Alt", [item])
        })
    }

    /// An ordered list with one item.
    func setSeq(_ ns: String, _ prefix: String, _ name: String, _ value: String?) {
        put(ns, prefix, name, value.map { list(ns, name, "Seq", [XmlElement(XmlName(Self.rdf, "li"), text: Self.clean($0))]) })
    }

    /// An unordered list, or nothing when there are no values.
    func setBag(_ ns: String, _ prefix: String, _ name: String, _ values: [String]) {
        put(ns, prefix, name, values.isEmpty ? nil : list(ns, name, "Bag", values.map { XmlElement(XmlName(Self.rdf, "li"), text: Self.clean($0)) }))
    }

    func toBytes() -> [UInt8] {
        document.serialize()
    }

    // XML has no place for most control characters, U+FFFE or U+FFFF, and XmlWriter refuses them; a title that holds one
    // would stop the whole write. They are left out of the packet, and /Info keeps the text as it is.
    private static func clean(_ value: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: value.unicodeScalars.filter { XmlParser.isChar($0) })
        return String(kept)
    }

    private func list(_ ns: String, _ name: String, _ kind: String, _ items: [XmlElement]) -> XmlElement {
        let container = XmlElement(XmlName(Self.rdf, kind))
        for item in items { container.append(item) }
        let property = XmlElement(XmlName(ns, name))
        property.append(container)
        return property
    }

    private func descriptions() -> [XmlElement] {
        rdfElement.elements(XmlName(Self.rdf, "Description"))
    }

    private func put(_ ns: String, _ prefix: String, _ name: String, _ element: XmlElement?) {
        for description in descriptions() {
            description.removeAttribute(XmlName(ns, name))
            description.element(XmlName(ns, name))?.remove()
        }
        guard let element else { return }
        let target: XmlElement
        if let first = descriptions().first {
            target = first
        } else {
            target = XmlElement(XmlName(Self.rdf, "Description"))
            target.attributes.append(XmlAttribute(XmlName(Self.rdf, "about"), ""))
            rdfElement.append(target)
        }
        if target.prefixOfNamespace(ns, allowDefault: false) == nil { target.setAttributeValue(XmlName(XmlNamespaces.xmlns, prefix), ns) }
        target.append(element)
    }
}
